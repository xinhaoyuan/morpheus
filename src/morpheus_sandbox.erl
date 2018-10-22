-module(morpheus_sandbox).

-export([ start/3
        , start/4
        ]).

%% For client api
-export([ get_ctl/0
        , get_node/0
        , call_ctl/3
        , cast_ctl/2
        , start_node/4
        , set_flag/2
        ]).

-export([ to_handle/4
        , is_undet_nif/4
        , to_override/4
        , to_expose/4
        ]).

-export([ handle/5
        , handle_erlang_spawn/3, handle_erlang_spawn/4, handle_erlang_spawn/5, handle_erlang_spawn/6
        , handle_erlang_spawn_opt/3, handle_erlang_spawn_opt/5
        , hibernate_entry/3
        ]).

-include("morpheus_priv.hrl").
-include("morpheus_ctl_calls.hrl").
-include_lib("firedrill/include/firedrill.hrl").

-define(H, morpheus_helper).

-define(LOCAL_NODE_NAME, 'nonode@nohost').

%% Process dictionary keys in guest processes for internal use
-define(PDK_MOD_MAP, '$sandbox_mod_map').
-define(PDK_CTL, '$sandbox_ctl').
-define(PDK_NODE, '$sandbox_node').
-define(PDK_OPT, '$sandbox_opt').
-define(PDK_SHTAB, '$sandbox_shtab').
-define(PDK_ABS_ID, '$sandbox_abs_id').
-define(PDK_CREATION_COUNT, '$sandbox_creation_count').
-define(IS_INTERNAL_PDK(X),
        (case (X) of
             ?PDK_MOD_MAP -> true;
             ?PDK_CTL -> true;
             ?PDK_NODE -> true;
             ?PDK_OPT -> true;
             ?PDK_SHTAB -> true;
             ?PDK_ABS_ID -> true;
             ?PDK_CREATION_COUNT -> true;
             _ -> false
         end)).

-type abs_id() :: integer().

-record(sandbox_opt,
        { verbose_ctl_req       :: boolean()
        , verbose_handle        :: boolean()
        , trace_receive         :: boolean()
        , trace_send            :: boolean()
        , control_timeouts      :: boolean()
        , time_uncertainty      :: integer()
        , stop_on_deadlock      :: boolean()
        , heartbeat             :: false | once | integer()
        , aux_module            :: undefined | module()
        , undet_timeout         :: integer()
        , fd_opts               :: term()
        , fd_scheduler          :: pid()
        , et_collector          :: pid()
        }).
-record(timeout_entry,
        { type   :: atom()
        , ref    :: reference()
        , proc   :: pid()
        , vclock :: integer()
        }).
-record(sandbox_state,
        { opt              :: #sandbox_opt{}
        , initial          :: boolean()
        , mod_table        :: ?TABLE_TYPE()
        , proc_table       :: ?TABLE_TYPE()
        , proc_shtable     :: ?SHTABLE_TYPE()
        , res_table        :: dict:dict()
        , abs_id_table     :: dict:dict(pid(), abs_id())
        , abs_id_counter   :: abs_id()
        , transient_counter:: integer()
        , alive            :: [pid()]
        , alive_counter    :: integer()
        , buffer_counter   :: integer()
        , buffer           :: [{abs_id(), #fd_delay_req{}, term()}]
        , waiting_counter  :: integer()
        , waiting          :: dict:dict()
        , vclock_offset    :: integer()
        , vclock           :: integer()
        , vclock_limit     :: integer()
        , unique_integer   :: integer()
        , timeouts_counter :: integer()
        , timeouts         :: [#timeout_entry{}]
        , undet_signals    :: integer()
        , undet_kick       :: undefined | reference()
        , undet_nifs       :: [{atom(), atom(), integer()} | {atom(), atom()} | {atom()} | atom()]
        }).

ctl_state_format(S) ->
    io_lib_pretty:print(
      S#sandbox_state{
        abs_id_table = dict:to_list(S#sandbox_state.abs_id_table),
        waiting = dict:to_list(S#sandbox_state.waiting),
        res_table = dict:to_list(S#sandbox_state.res_table)
       },
      %% Must do case by case since record_info doesn't take variables
      fun (sandbox_opt, Size) ->
              case Size + 1 =:= record_info(size, sandbox_opt) of
                  true ->
                      record_info(fields, sandbox_opt);
                  false ->
                      no
              end;
          (sandbox_state, Size) ->
              case Size + 1 =:= record_info(size, sandbox_state) of
                  true ->
                      record_info(fields, sandbox_state);
                  false ->
                      no
              end;
          (_, _) -> no
      end).

-compile({nowarn_unused_function, [sht_abs_id/2]}).
sht_abs_id(SHT, Proc) ->
    case ?SHTABLE_GET(SHT, {abs_id, Proc}) of
        {_, AbsId} ->
            AbsId;
        undefined ->
            Proc
    end.

ctl_trace_send(#sandbox_opt{aux_module = Aux} = Opt, SHT,
               Where, From, To, Type, Content, Effect) ->
    case Aux =:= undefined
        orelse not erlang:function_exported(Aux, trace_send_filter, 4)
        orelse Aux:trace_send_filter(From, To, Type, Content) of
        true ->
            ctl_trace_send_real(Opt, SHT, Where, From, To, Type, Content, Effect);
        _ ->
            ok
    end.

ctl_trace_send_real(_Opt, _SHT,
                    Where, From, To, message, Msg, Effect) ->
    ?INFO("~w@~p -m-> ~w (~w):~n  ~p", [From, Where, To, Effect, Msg]);
ctl_trace_send_real(_Opt, _SHT,
                    Where, From, To, signal, Reason, _Effect) ->
    ?INFO("~w@~p -!-> ~w signal:~n  ~p", [From, Where, To, Reason]).

ctl_trace_receive(#sandbox_opt{aux_module = Aux} = Opt, SHT,
                  Where, To, Type, Content) ->
    case Aux =:= undefined
        orelse not erlang:function_exported(Aux, trace_receive_filter, 3)
        orelse Aux:trace_receive_filter(To, Type, Content) of
        true ->
            ctl_trace_receive_real(Opt, SHT, To, Where, Type, Content);
        _ ->
            ok
    end.

ctl_trace_receive_real(_Opt, _SHT,
                       Where, Proc, message, Msg) ->
    ?INFO("~w@~p <-m-:~n  ~p", [Proc, Where, Msg]);
ctl_trace_receive_real(_Opt, _SHT,
                       Where, Proc, Type, undefined) ->
    ?INFO("~w@~p <-!-:~n  ~p", [Proc, Where, Type]).

%% Currently, proc_table contains the following kinds of entries:
%% {proc, PID} -> {alive, dict:dict()} | {tomb, Node}
%% {msg_queue, PID} -> [term()]
%% {monitor, Ref} -> {Watcher, Target, Object} - note that it's possible to have Watcher =:= Target
%% {watching, PID} -> [{Ref, PID}]
%% {monitored_by, PID} -> [{Ref, PID, Object}]
%% {link, PID1, PID2} -> true - If {link, PID1, PID2} exists, {link, PID2, PID1} must exists; also it's guaranteed that PID1 =/= PID2
%% {linking, PID} -> [PID]
%% {reg, Node, Name} -> {proc, PID} | {external_proc, PID} | {port_agent, PID}
%% {name, PID} -> {Node, Name}
%% {node_procs, Node} -> [PID]
%% {node, Node} -> {online|offline, dict:dict()}
%% online_nodes -> [NodeId]
%%
%% {reg, Node, Name} is allowed to map to external pid (through process_register_external ctl call)
%% {external_proc, PID} -> {Node, Name}
%% {port_agent, PID} -> {Node, Name}

%% proc_shtable stores shared but transient data for communication
%% between sandboxed processes and ctl:
%% {exit, PID} -> Reason - exit signal
%% {ets, RealEtsRef} -> {VirtualEtsRef, Owner, HeirInfo} - set before a sandbox process give ets control to sandbox ctl 
%% {abs_id, PID} -> [Node, PList] - shared mapping of abstract id of process

-ifdef(OTP_RELEASE).
-define(CATCH(EXP), ((fun () -> try {ok, EXP} catch error:R:ST -> {error, R, ST}; exit:R:ST -> {exit, R, ST}; throw:R:ST -> {throw, R, ST} end end)())).
-else.
-define(CATCH(EXP), ((fun () -> try {ok, EXP} catch error:R -> {error, R, erlang:get_stacktrace()}; exit:R -> {exit, R, erlang:get_stacktrace()}; throw:R -> {throw, R, erlang:get_stacktrace()} end end)())).
-endif.

ctl_init(Opts) ->
    process_flag(trap_exit, true),
    ensure_preloaded_path(),
    PT = ?TABLE_SET(?TABLE_NEW(), online_nodes, []),
    SHT = ?SHTABLE_NEW(),
    case proplists:get_value(trace_from_start, Opts) of
        undefined ->
            ok;
        V ->
            ?SHTABLE_SET(SHT, tracing, V)
    end,
    FdOpts = proplists:get_value(fd_opts, Opts, undefined),
    FdSched =
        case FdOpts of
            undefined ->
                proplists:get_value(fd_scheduler, Opts, undefined);
            _ ->
                %% XXX avoid using magic name
                firedrill:start(
                  [ {use_fd_sup, false}
                  , {try_fire_timeout, infinity}
                    | FdOpts ]),
                whereis(fd_sched)
        end,
    S = #sandbox_state
        { opt = #sandbox_opt
          { verbose_ctl_req       = proplists:get_value(verbose_ctl, Opts, false)
          , verbose_handle        = proplists:get_value(verbose_handle, Opts, false)
          , trace_receive         = proplists:get_value(trace_receive, Opts, false)
          , trace_send            = proplists:get_value(trace_send, Opts, false)
          , control_timeouts      = proplists:get_value(control_timeouts, Opts, true)
          , time_uncertainty      = proplists:get_value(time_uncertainty, Opts, 0)
          , stop_on_deadlock      = proplists:get_value(stop_on_deadlock, Opts, true)
          , heartbeat             = proplists:get_value(heartbeat, Opts, 10000)
          , aux_module            = proplists:get_value(aux_module, Opts, undefined)
          , undet_timeout         = proplists:get_value(undet_timeout, Opts, 50)
          , fd_opts               = FdOpts
          , fd_scheduler          = FdSched
          , et_collector          = proplists:get_value(et_collector, Opts, undefined)
          }
        , initial = true
        , mod_table = ?TABLE_NEW()
        , proc_table = PT
        , proc_shtable = SHT
        , res_table = dict:new()
        , abs_id_table = dict:new()
        , abs_id_counter = 0
        , transient_counter = 0
        , alive = []
        , alive_counter = 0
        , buffer_counter = 0
        , buffer = []
        , waiting_counter = 0
        , waiting = dict:new()
        , vclock_offset = proplists:get_value(clock_offset, Opts, erlang:system_time(millisecond))
        , vclock = proplists:get_value(clock_base, Opts, 0)
        , vclock_limit = proplists:get_value(clock_limit, Opts, infinity)
        , unique_integer = 1
        , timeouts_counter = 0
        , timeouts = []
        , undet_signals = 0
        , undet_kick = undefined
        , undet_nifs = proplists:get_value(undet_nifs, Opts, [])
        },
    S.

ensure_preloaded_path() ->
    case code:get_object_code(erlang) of
        error ->
            code:add_pathz(filename:join(code:root_dir(), "erts/preloaded/ebin"));
        _ -> ok
    end.

start(M, F, A) ->
    start(M, F, A, []).

start(M, F, A, Opts) ->
    Ctl = spawn(fun () ->
                        S = ctl_init(Opts),
                        ctl_check_heartbeat(S),
                        ctl_loop(S)
                end),
    Ret =
        case lists:member(monitor, Opts) of
            true ->
                {Ctl, monitor(process, Ctl)};
            false ->
                Ctl
        end,
    Node = proplists:get_value(node, Opts, node()),
    {ok, ok} = ?cc_node_created(Ctl, global_start, Node),
    {ok, Opt} = ?cc_get_opt(Ctl, global_start),
    {ok, ShTab} = ?cc_get_shtab(Ctl, global_start),
    {ok, {NewM, Nifs}} = ?cc_instrument_module(Ctl, global_start, M),
    {ok, {NewGI, []}} = ?cc_instrument_module(Ctl, global_start, morpheus_guest_internal),
    RealM =
        case lists:member({F, length(A)}, Nifs) of
            true ->
                ?WARNING("Trying to spawn a initial process with nif entry ~p - this may go wild!", [{M, F, A}]),
                M;
            false -> NewM
        end,
    Pid = spawn(fun () ->
                        %% virtual init process!
                        erlang:group_leader(self(), self()),
                        instrumented_process_start(Ctl, Node, Opt, ShTab),
                        ?cc_initial_kick(Ctl, global_start),
                        NewGI:init(),
                        instrumented_process_end(?CATCH(apply(RealM, F, A)))
                end),
    instrumented_process_created(Ctl, global_start, ShTab, Node, Pid),
    instrumented_process_kick(Ctl, Node, Pid),
    Ret.

call_ctl(Ctl, Where, Args) ->
    MRef = erlang:monitor(process, Ctl),
    Ctl ! {call, Where, self(), MRef, Args},
    receive
        {MRef, Ret} ->
            erlang:demonitor(MRef, [flush]),
            {ok, Ret};
        {'DOWN', MRef, _, _, _} ->
            {failed, 'DOWN'}
    end.

cast_ctl(Ctl, Args) ->
    Ctl ! {cast, Args}.

ctl_check_heartbeat(#sandbox_state{opt = #sandbox_opt{heartbeat = HB}} = S) when is_integer(HB) ->
    ?INFO("ctl heartbeat:~n~s", [ctl_state_format(S)]),
    erlang:send_after(HB, self(), {heartbeat});
ctl_check_heartbeat(#sandbox_state{opt = #sandbox_opt{heartbeat = once}} = S) ->
    ?INFO("ctl heartbeat:~n~s", [ctl_state_format(S)]);
ctl_check_heartbeat(_) ->
    ok.

ctl_loop(S0) ->
    {S, M} = ctl_check_and_receive(S0),
    #sandbox_state{opt = Opt, initial = Initial, abs_id_table = AIDT} = S,
    #sandbox_opt{verbose_ctl_req = Verbose} = Opt,
    ToTrace =
        case Verbose of
            true ->
                case ?SHTABLE_GET(S#sandbox_state.proc_shtable, tracing) of
                    {_, true} -> true;
                    _ -> false
                end;
            false -> false
        end,
    case M of
        {call, Where, Pid, Ref, Req} ->
            case not Initial
                andalso ctl_call_can_buffer(Req)
                andalso dict:find(Pid, AIDT) of
                {ok, Aid} ->
                    case Req of
                        %% Special handling of undet_barrier -- only buffer when there is any undet signal
                        {undet_barrier} when S#sandbox_state.undet_signals > 0 ->
                            case ToTrace of
                                true -> ?INFO("delay undet_barrier ~p", [Req]);
                                false -> ok
                            end,
                            ctl_loop(ctl_push_request_to_buffer(S, Where, Aid, Pid, Ref, {undet_barrier, true}));
                        {undet_barrier} ->
                            ctl_loop(ctl_loop_call(S, Where, ToTrace, Pid, Ref, {undet_barrier, false}));
                        {undet, _} ->
                            case ToTrace of
                                true -> ?INFO("delay undet resp ~p", [Req]);
                                false -> ok
                            end,
                            Pid ! {Ref, ok},
                            ctl_loop(ctl_push_request_to_buffer(S, Where, Aid, undet, Ref, Req));
                        _ ->
                            case ToTrace of
                                true -> ?INFO("delay resp ~p", [Req]);
                                false -> ok
                            end,
                            ctl_loop(ctl_push_request_to_buffer(S, Where, Aid, Pid, Ref, Req))
                    end;
                error ->
                    ctl_loop(ctl_loop_call(S, Where, ToTrace, Pid, Ref, Req));
                false ->
                    ctl_loop(ctl_loop_call(S, Where, ToTrace, Pid, Ref, Req))
            end;
        #fd_delay_resp{ref = Ref} ->
            {SAfterPop, Where, ReplyTo, Ref, Req} = ctl_pop_request_from_buffer(S, Ref),
            case ToTrace of
                true -> ?INFO("resume resp ~p", [Req]);
                false -> ok
            end,
            case ReplyTo of
                timeout ->
                    ctl_loop(ctl_handle_cast(SAfterPop, Req));
                _ ->
                    ctl_loop(ctl_loop_call(SAfterPop, Where, ToTrace, ReplyTo, Ref, Req))
            end;
        {cast, {stop, Reason}} ->
            ctl_exit(S, Reason);
        {cast, Req} ->
            case ToTrace of
                true ->
                    ?INFO( "ctl cast req ~p", [Req]);
                false -> ok
            end,
            NewS = ctl_handle_cast(S, Req),
            ctl_loop(NewS);
        {timeout, TRef, Req} ->
            case ToTrace of
                true ->
                    ?INFO( "ctl timeout cast req ~p", [Req]);
                false -> ok
            end,
            NewS = ctl_handle_cast(S, {timeout, TRef, Req}),
            ctl_loop(NewS);
        %% not sure how to forward io request properly now
        %% {io_request, Pid, Ref, Req} = IOReq ->
        %%     user ! IOReq;
        {'EXIT', Pid, Reason} ->
            ?WARNING("Uncaught exit from ~p with reason ~p", [Pid, Reason]),
            ctl_loop(S);
        {heartbeat} ->
            ctl_check_heartbeat(S),
            ctl_loop(S);
        {'ETS-TRANSFER', _, _, morpheus_internal} ->
            ctl_loop(S);
        M ->
            ?WARNING("ctl ignored ~p", [M]),
            ctl_loop(S)
    end.


ctl_push_request_to_buffer(
  #sandbox_state{ buffer_counter = BC
                , buffer = Buffer
                , waiting_counter = WC
                , waiting = Waiting} = S,
  Where, AID, ReplyTo, Ref, Req) ->
    NewWaiting = dict:store(Ref, {Where, ReplyTo, Req}, Waiting),
    NewBuffer = [{case ReplyTo of
                      undet -> -AID - 1;
                      _ -> AID
                  end,
                  #fd_delay_req{ref = Ref,
                                %% if use firedrill, it will reply to ctl
                                from = self(),
                                to = ctl_call_target(Req),
                                type = ctl_call_target_type(Req),
                                data = hidden_by_morpheus
                               },
                  Req}
                 | Buffer],
    case ReplyTo of
        undet ->
            %% Undet async request
            %% Don't decrease alive_counter.
            S#sandbox_state{buffer = NewBuffer,
                            buffer_counter = BC + 1,
                            waiting_counter = WC + 1,
                            waiting = NewWaiting,
                            undet_signals = S#sandbox_state.undet_signals + 1
                           };
        timeout ->
            S#sandbox_state{buffer = NewBuffer,
                            buffer_counter = BC + 1,
                            waiting_counter = WC + 1,
                            waiting = NewWaiting
                           };
        _ ->
            S#sandbox_state{alive = S#sandbox_state.alive -- [ReplyTo],
                            alive_counter = S#sandbox_state.alive_counter - 1,
                            buffer = NewBuffer,
                            buffer_counter = BC + 1,
                            waiting_counter = WC + 1,
                            waiting = NewWaiting
                           }
    end.

ctl_pop_request_from_buffer(#sandbox_state{waiting_counter = WC, waiting = Waiting} = S, Ref) ->
    case dict:take(Ref, Waiting) of
        error ->
            error(pop_request_failed);
        {{Where, ReplyTo, Req}, NewWaiting} ->
            case ReplyTo of
                undet ->
                    %% undet async request
                    {S#sandbox_state{waiting_counter = WC - 1,
                                     waiting = NewWaiting},
                     Where, ReplyTo, Ref, Req};
                timeout ->
                    {S#sandbox_state{waiting_counter = WC - 1,
                                     waiting = NewWaiting},
                     Where, ReplyTo, Ref, Req};
                _ ->
                    {S#sandbox_state{alive = [ReplyTo | S#sandbox_state.alive],
                                     alive_counter = S#sandbox_state.alive_counter + 1,
                                     waiting_counter = WC - 1,
                                     waiting = NewWaiting},
                     Where, ReplyTo, Ref, Req}
            end
    end.

ctl_push_request_to_scheduler(#sandbox_state{opt = #sandbox_opt{fd_scheduler = Sched}} = S,
                              Req) when Sched =/= undefined ->
    Sched ! Req,
    S.

ctl_notify_scheduler(#sandbox_state{opt = #sandbox_opt{fd_scheduler = Sched}} = S)
  when Sched =/= undefined ->
    Sched ! fd_notify_idle,
    S.

ctl_check_and_receive(#sandbox_state{initial = true} = S) ->
    receive M -> {S, M} end;
ctl_check_and_receive(#sandbox_state{opt = Opt,
                                     alive_counter = AC, timeouts_counter = TimeoutsC,
                                     buffer_counter = BC, waiting_counter = WC,
                                     undet_signals = UndetSigs, undet_kick = UndetKick} = S) ->
    receive
        M -> {S, M}
    after 0 ->
            %% only handle deadlocks and kick if there is no pending request in ctl
            NewS =
                if
                    AC =:= 0,
                    UndetSigs =< 0,
                    WC =:= 0,
                    TimeoutsC =:= 0 ->
                        if
                            S#sandbox_state.transient_counter > 0 ->
                                case S#sandbox_state.opt of
                                    #sandbox_opt{stop_on_deadlock = true} ->
                                        cast_ctl(self(), {stop, deadlock});
                                    _ ->
                                        ?WARNING("Nothing is alive now. Deadlock?", [])
                                end;
                            true ->
                                cast_ctl(self(), {stop, normal})
                        end,
                        S;
                    AC =:= 0,
                    UndetSigs =< 0,
                    BC > 0 ->
                        %% Flush the buffer and handle them deterministically
                        #sandbox_state{buffer = Buffer} = S,
                        #sandbox_opt{fd_scheduler = Sched, aux_module = Aux} = Opt,
                        SortedBuffer = lists:keysort(1, Buffer),
                        {S1, _, ToNotify} =
                            lists:foldl(
                              fun ({AID, DelayReq, OriginReq}, {CurS, LastAID, ToNotify}) ->
                                      case LastAID of
                                          AID ->
                                              ?ERROR("Buffered requests with the same AID. This may lead to non-determinism", []);
                                          _ -> ok
                                      end,
                                      case (Sched =/= undefined) andalso
                                          ctl_call_to_delay(
                                            Aux =:= undefined orelse
                                            not erlang:function_exported(Aux, to_delay_call, 4),
                                            OriginReq) of
                                          true ->
                                              {ctl_push_request_to_scheduler(CurS, DelayReq), AID, ToNotify};
                                          false ->
                                              self() ! #fd_delay_resp{ref = DelayReq#fd_delay_req.ref},
                                              {CurS, AID, false}
                                      end
                              end,
                              {S#sandbox_state{buffer = [], buffer_counter = 0}, undefined, true},
                              SortedBuffer),
                        case (Sched =/= undefined) andalso ToNotify of
                            true ->
                                ctl_notify_scheduler(S1);
                            false ->
                                S1
                        end;
                    AC =:= 0,
                    UndetSigs =< 0,
                    BC =:= 0,
                    WC > 0 ->
                        #sandbox_opt{fd_scheduler = Sched} = Opt,
                        case Sched of
                            undefined ->
                                ?WARNING("WTF?", []);
                            _ ->
                                Sched ! fd_notify_idle
                        end,
                        S;
                    AC =:= 0,
                    UndetSigs =< 0,
                    WC =:= 0,
                    TimeoutsC > 0 ->
                        case S#sandbox_state.opt#sandbox_opt.control_timeouts of
                            true->
                                cast_ctl(self(), {kick_timeouts});
                            false ->
                                ok
                        end,
                        S;
                    AC =:= 0, UndetSigs > 0, UndetKick =:= undefined ->
                        S#sandbox_state{undet_kick = erlang:start_timer(Opt#sandbox_opt.undet_timeout, self(), {undet_kick})};
                    AC < 0; TimeoutsC < 0; WC < 0->
                        ?WARNING("WTF? ~p ~p ~p", [AC, TimeoutsC, WC]),
                        S;
                    true ->
                        S
                end,
            %% Revert the potential transient tick
            NewS1 =
                if
                    UndetSigs < 0 ->
                        NewS#sandbox_state{undet_signals = -UndetSigs, undet_kick = undefined};
                    UndetSigs =:= 0, UndetKick =/= undefined ->
                        NewS#sandbox_state{undet_kick = undefined};
                    true ->
                        NewS
                end,
            {NewS1, receive M -> M end}
    end.

ctl_call_can_buffer({nodelay, _}) -> false;
%% we want the timeout to start soon, so do not buffer.
ctl_call_can_buffer({undet}) -> false;
%% {undet, _} is delayable since we need to buffer it
ctl_call_can_buffer(_) -> true.

ctl_call_to_delay(true, {nodelay, _}) -> false;
ctl_call_to_delay(true, ?cci_undet()) -> false;
ctl_call_to_delay(true, {undet, _}) -> false;
ctl_call_to_delay(true, {undet_barrier, _}) -> false;
ctl_call_to_delay(true, ?cci_initial_kick()) -> false;
ctl_call_to_delay(true, ?cci_get_shtab()) -> false;
ctl_call_to_delay(true, ?cci_get_opt()) -> false;
ctl_call_to_delay(true, {resource_acquire, _}) -> false;
ctl_call_to_delay(true, ?cci_instrument_module(_)) -> false;
ctl_call_to_delay(true, ?cci_node_created(_)) -> false;
ctl_call_to_delay(true, ?cci_instrumented_process_created(_, _)) -> false;
ctl_call_to_delay(true, ?cci_process_receive(_, _, _)) -> false;
%% ctl_call_to_delay(true, {receive_timeout, _, _}) -> false;
%% to delay?
ctl_call_to_delay(true, ?cci_get_clock()) -> false;
ctl_call_to_delay(true, _) -> true;
%%%%
ctl_call_to_delay(false, {delay}) -> true;
ctl_call_to_delay(false, {delay, _}) -> true;
ctl_call_to_delay(false, _) -> false.

ctl_call_target(_) -> morpheus.

ctl_call_target_type(_) -> morpheus_call.

ctl_loop_call(S, Where, ToTrace,
              ReplyTo, Ref, Req) ->
    case ToTrace of
        true ->
            ?INFO("ctl req ~p", [Req]);
        false -> ok
    end,
    {NewS, Ret} = ctl_handle_call(S, Where, Req),
    case ToTrace of
        true ->
            ?INFO("ctl resp ~p", [Ret]);
        false -> ok
    end,
    case ReplyTo of
        undet ->
            ok;
        _ when is_pid(ReplyTo) ->
            ReplyTo ! {Ref, Ret}
    end,
    NewS.

ctl_handle_call(S, Where, {nodelay, Req}) ->
    ctl_handle_call(S, Where, Req);
ctl_handle_call(S, _Where, {delay}) ->
    {S, ok};
ctl_handle_call(S, Where, {delay, Req}) ->
    ctl_handle_call(S, Where, Req);
ctl_handle_call(S, Where, {maybe_delay, Req}) ->
    ctl_handle_call(S, Where, Req);
ctl_handle_call(S, _Where, {log, _}) ->
    {S, ok};
ctl_handle_call(S, _Where, ?cci_initial_kick()) ->
    {S#sandbox_state{initial = false}, ok};
ctl_handle_call(S, _Where, {ets_op}) ->
    {S, ok};
ctl_handle_call(#sandbox_state{proc_table = PT} = S,
                _Where, ?cci_ets_all()) ->
    Ret = lists:foldr(
            fun (Tab, Acc) ->
                    Owner = ets:info(Tab, owner),
                    case ?TABLE_GET(PT, {proc, Owner}) of
                        {_, {alive, _}} ->
                            [Tab | Acc];
                        _ ->
                            Acc
                    end
            end, [], ets:all()),
    {S, Ret};
ctl_handle_call(#sandbox_state{undet_signals = UndetSigs} = S,
                _Where, {undet}) ->
    {S#sandbox_state{undet_signals = UndetSigs + 1}, ok};
ctl_handle_call(#sandbox_state{undet_signals = UndetSigs} = S,
                Where, {undet, R}) ->
    ctl_handle_call(S#sandbox_state{undet_signals = UndetSigs + 1}, Where, R);
ctl_handle_call(S, _Where, {undet_barrier, Result}) ->
    %% The result is written in push_req
    {S, Result};
% internal use only
ctl_handle_call(#sandbox_state{transient_counter = TC} = S,
                _Where, {become_persistent, _Proc}) ->
    {S#sandbox_state{transient_counter = TC - 1}, ok};
ctl_handle_call(#sandbox_state{opt = Opt} = S,
                _Where, ?cci_get_opt()) ->
    {S, Opt};
ctl_handle_call(#sandbox_state{proc_shtable = ShTab} = S,
                _Where, ?cci_get_shtab()) ->
    {S, ShTab};
ctl_handle_call(#sandbox_state{opt = Opt} = S,
                _Where, ?cci_get_clock()) ->
    case Opt#sandbox_opt.control_timeouts of
        true ->
            #sandbox_state{vclock = VC, vclock_offset = VCO} = S,
            {S, {VC, VCO}};
        false ->
            {S, {erlang:monotonic_time(millisecond), erlang:time_offset(millisecond)}}
    end;
ctl_handle_call(#sandbox_state{unique_integer = UI} = S,
                _Where, ?cci_unique_integer()) ->
    {S#sandbox_state{unique_integer = UI + 1}, UI};
ctl_handle_call(#sandbox_state{mod_table = MT} = S,
                _Where, ?cci_instrument_module(M)) ->
    case ?TABLE_GET(MT, M) of
        {M, {NewM, Nifs}} ->
            {S, {NewM, Nifs}};
        undefined ->
            case
                ?CATCH(
                   begin
                       ?DEBUG("Instrumenting ~p", [M]),
                       NewM = list_to_atom("$M$" ++ pid_to_list(self()) ++ "$" ++ atom_to_list(M)),
                       {M, ObjectCode, Filename} =
                           case code:get_object_code(M) of
                               error ->
                                   ?WARNING("Cannot instrument module ~p. "
                                            "Will use the original module. "
                                            "To fix, use code:add_path/1 outside the sanbdox.", [M]),
                                   throw(skip);
                                   %% case code:which(M) of
                                   %%     preloaded ->
                                   %%         #sandbox_state{opt = #sandbox_opt{preloaded_root = Root}} = S,
                                   %%         case Root of
                                   %%             _ when is_list(Root) ->
                                   %%                 {M,
                                   %%                  Root ++ "/ebin/" ++ atom_to_list(M) ++ ".beam",
                                   %%                  %% XXX or use beam file instead?
                                   %%                  Root ++ "/src/" ++ atom_to_list(M) ++ ".erl"};
                                   %%             _ ->
                                   %%                 ?WARNING("Cannot instrument preloaded module ~p. "
                                   %%                          "Will use the original module. "
                                   %%                          "Set preloaded_root if you want to instrument it.", [M]),
                                   %%                 throw(skip)
                                   %%         end;
                                   %%     _ ->
                                   %%         error(cannot_get_object_code)
                                   %% end;
                               {_, _, _} = _Result -> _Result
                           end,
                       {ok, S1, Nifs, _} = morpheus_instrument:instrument_and_load(?MODULE, S, M, NewM, Filename, ObjectCode),
                       NewMT = ?TABLE_SET(MT, M, {NewM, Nifs}),
                       {S1#sandbox_state{mod_table = NewMT}, {NewM, Nifs}}
                   end)
            of
                {ok, Result} -> Result;
                {throw, skip, _} ->
                    {S#sandbox_state{mod_table = ?TABLE_SET(MT, M, {M, []})}, {M, []}};
                Other ->
                    ?ERROR("Cannot instrument module ~p: ~p", [M, Other]),
                    error(cannot_instrument)
            end
    end;
ctl_handle_call(#sandbox_state{proc_table = PT} = S,
                _Where, {node_created, Node}) ->
    case ?TABLE_GET(PT, {node, Node}) of
        {_, _} ->
            ?ERROR("node_created happened twice", []),
            {S, badarg};
        undefined ->
            PT0 = ?TABLE_SET(PT,  {node, Node}, {offline, dict:new()}),
            PT1 = ?TABLE_SET(PT0, {node_procs, Node}, []),
            {S#sandbox_state{proc_table = PT1}, ok}
    end;
ctl_handle_call(#sandbox_state{proc_table = PT} = S,
                _Where, {node_set_alive, Node, Alive}) ->
    SetTo = case Alive of true -> online; false -> offline end,
    case ?TABLE_GET(PT, {node, Node}) of
        {_, {SetTo, _}} ->
            {S, true};
        {_, {offline, Props}} ->
            %% bring offline to online
            {_, Procs} = ?TABLE_GET(PT, {node_procs, Node}),
            Succ =
                lists:foldr(
                  fun (Proc, true) ->
                          case (catch erlang:set_fake_node(Proc, Node)) of
                              ok -> true;
                              _ ->
                                  ?WARNING("set_fake_node not supported. Cannot emulate dist erlang", []),
                                  false
                          end;
                      (_Proc, false) ->
                          false
                  end, true, Procs),
            PT0 = ?TABLE_SET(PT, {node, Node}, {SetTo, Props}),
            PT1 =
                case ?TABLE_GET(PT0, online_nodes) of
                    {_, NodeList} ->
                        ?TABLE_SET(PT, online_nodes, NodeList ++ [Node])
                end,
            {S#sandbox_state{proc_table = PT1}, Succ};
        {_, {online, Props}} ->
            %% bring online to offline
            {_, Procs} = ?TABLE_GET(PT, {node_procs, Node}),
            Succ =
                lists:foldr(
                  fun (Proc, true) ->
                          case (catch erlang:set_fake_node(Proc, ?LOCAL_NODE_NAME)) of
                              ok -> true;
                              _ ->
                                  ?WARNING("set_fake_node not supported. Cannot emulate dist erlang", []),
                                  false
                          end;
                      (_Proc, false) ->
                          false
                  end, true, Procs),
            PT0 = ?TABLE_SET(PT, {node, Node}, {SetTo, Props}),
            PT1 =
                case ?TABLE_GET(PT0, online_nodes) of
                    {_, NodeList} ->
                        ?TABLE_SET(PT, online_nodes, NodeList -- [Node])
                end,
            {S#sandbox_state{proc_table = PT1}, Succ};
        undefined ->
            {S, false}
    end;
ctl_handle_call(#sandbox_state{proc_table = PT} = S,
                _Where, ?cci_list_nodes(FromNode, Label)) ->
    {_, {Status, _}} = ?TABLE_GET(PT, {node, FromNode}),
    case Label of
        this ->
            case Status of
                offline ->
                    {S, [?LOCAL_NODE_NAME]};
                online ->
                    {S, [FromNode]}
            end;
        _ when Label =:= connected; Label =:= visible ->
            case Status of
                offline ->
                    {S, []};
                online ->
                    case ?TABLE_GET(PT, online_nodes) of
                        {_, NodeList} ->
                            {S, NodeList -- [FromNode]}
                    end
            end;
        _ when Label =:= hidden ->
            {S, []}
    end;
ctl_handle_call(#sandbox_state
                { opt = Opt
                , proc_table = PT
                , proc_shtable = SHT
                , abs_id_table = AIDT
                , abs_id_counter = AIDC
                , transient_counter = TC
                , alive_counter = AC} = S,
                _Where, ?cci_instrumented_process_created(Node, Proc)) ->
    case {?TABLE_GET(PT, {proc, Proc}), ?TABLE_GET(PT, {node, Node})} of
        {{_, _}, _} ->
            ?ERROR("instrumented_process_created happened twice", []),
            {S, badarg};
        {undefined, {_, {Status, _}}} when Status =:= offline; Status =:= online ->
            if
                Opt#sandbox_opt.trace_send; Opt#sandbox_opt.trace_receive ->
                    %% Do not hide this message
                    case ?SHTABLE_GET(SHT, {abs_id, Proc}) of
                        {_, AbsId} ->
                            ?INFO("~w created: ~w", [Proc, AbsId])
                    end;
                true -> ok
            end,
            erlang:link(Proc),
            PT0 = ?TABLE_SET(PT,  {proc, Proc}, {alive, dict:new()}),
            PT1 = ?TABLE_SET(PT0, {name, Proc}, {Node, []}),
            PT2 = ?TABLE_SET(PT1, {monitored_by, Proc}, []),
            PT3 = ?TABLE_SET(PT2, {watching, Proc}, []),
            PT4 = ?TABLE_SET(PT3, {linking, Proc}, []),
            PT5 = ?TABLE_SET(PT4, {msg_queue, Proc}, []),
            PT6 = ?TABLE_SET(PT5, {node_procs, Node},
                             case ?TABLE_GET(PT5, {node_procs, Node}) of
                                 {_, L} -> [Proc | L]
                             end),
            case Status of
                offline ->
                    catch erlang:set_fake_node(Proc, ?LOCAL_NODE_NAME);
                online ->
                    catch erlang:set_fake_node(Proc, Node)
            end,
            {S#sandbox_state{proc_table = PT6, abs_id_table = dict:store(Proc, AIDC, AIDT), abs_id_counter = AIDC + 1,
                             transient_counter = TC + 1,
                             alive = [Proc | S#sandbox_state.alive],
                             alive_counter = AC + 1}, ok};
        {undefined, {_, OtherStatus}} ->
            ?ERROR("instrumented_process_created: node ~p is not alive, status: ~p", [Node, OtherStatus]),
            {S, badarg}
    end;
ctl_handle_call(#sandbox_state{proc_table = PT} = S,
                _Where, ?cci_instrumented_process_list(Node)) ->
    {S, case ?TABLE_GET(PT, {node_procs, Node}) of
            {_, L} -> L;
            undefined -> []
        end};
ctl_handle_call(#sandbox_state{proc_table = PT} = S,
                _Where, ?cci_instrumented_registered_list(Node)) ->
    %% XXX make it faster?
    NameList = ?TABLE_FOLD(
                  PT,
                  fun ({{reg, RNode, Name}, _}, Acc) ->
                          case RNode of
                              Node ->
                                  [Name | Acc];
                              _ ->
                                  Acc
                          end;
                      (_, Acc) -> Acc
                  end, []),
    {S, NameList};
ctl_handle_call(#sandbox_state{proc_table = PT} = S,
                _Where, ?cci_process_link(PA, PB)) ->
    case {?TABLE_GET(PT, {linking, PA}), ?TABLE_GET(PT, {linking, PB})} of
        {{_, LA}, {_, LB}} ->
            case PA =/= PB andalso ?TABLE_GET(PT, {link, PA, PB}) of
                false ->
                    {S, true};
                {{link, PA, PB}, true} ->
                    {S, true};
                undefined ->
                    PT0 = ?TABLE_SET(PT, {link, PA, PB}, true),
                    PT1 = ?TABLE_SET(PT0, {link, PB, PA}, true),
                    PT2 = ?TABLE_SET(PT1, {linking, PA}, [PB | LA]),
                    PT3 = ?TABLE_SET(PT2, {linking, PB}, [PA | LB]),
                    {S#sandbox_state{proc_table = PT3}, true}
            end;
        Other ->
            case {?TABLE_GET(PT, {proc, PA}), ?TABLE_GET(PT, {proc, PB})} of
                {{_, {alive, Props}}, {_, {tomb, TNode}}} ->
                    case ?TABLE_GET(PT, {name, PA}) of
                        {_, {TNode, _}} ->
                            %% local node
                            {S, noproc};
                        {_, {_OtherNode, _}} ->
                            case dict:find(trap_exit, Props) of
                                {ok, true} ->
                                    {S0, ok} = ctl_process_send(S, system, undefined, PA, {'EXIT', PB, noproc}),
                                    {S0, true};
                                _ ->
                                    %% Should we send signal noproc?
                                    ?INFO("~w: return noproc when linking to some dead remote proc ~w ... maybe problematic?", [PA, PB]),
                                    {S, noproc}
                            end
                    end;
                {{_, {alive, _Props}}, undefined} ->
                    ?WARNING("ignored link ~p with external process ~p", [PA, PB]),
                    {S, true};
                {{_, {tomb, _}}, _} ->
                    ?ERROR("process_link - zombie?", []),
                    %% Whatever ...
                    {S, noproc};
                Other ->
                    ?ERROR("Unhandled process_link ~p", [Other]),
                    {S, noproc}
            end
    end;
ctl_handle_call(#sandbox_state{proc_table = PT} = S,
                _Where, ?cci_process_unlink(PA, PB)) ->
    case PA =/= PB andalso ?TABLE_GET(PT, {link, PA, PB}) of
        false ->
            {S, true};
        {{link, PA, PB}, true} ->
            PT0 = ?TABLE_REMOVE(PT, {link, PA, PB}),
            PT1 = ?TABLE_REMOVE(PT0, {link, PB, PA}),
            {{_, LA}, {_, LB}} =
                {?TABLE_GET(PT, {linking, PA}), ?TABLE_GET(PT, {linking, PB})},
            PT2 = ?TABLE_SET(PT1, {linking, PA}, LA -- [PB]),
            PT3 = ?TABLE_SET(PT2, {linking, PB}, LB -- [PA]),
            {S#sandbox_state{proc_table = PT3}, true};
        undefined ->
            case {?TABLE_GET(PT, {proc, PA}), ?TABLE_GET(PT, {proc, PB})} of
                {{_, {alive, _}}, {_, {alive, _}}} ->
                    {S, true};
                {{_, {alive, _}}, {_, {tomb, _}}} ->
                    {S, true};
                {{_, {tomb, _}}, _} ->
                    ?ERROR("process_unlink - zombie?", []),
                    {S, true};
                Other ->
                    ?WARNING("Unhandled process_unlink ~p", [Other]),
                    {S, true}
            end
    end;
%%% For name based monitoring, I'm not sure how to handle node name regarding to offline/online switch.
ctl_handle_call(#sandbox_state{proc_table = PT} = S,
                _Where, ?cci_process_monitor(Watcher, FromNode, {TName, TNode})) ->
    case FromNode of
        [] ->
            ctl_monitor_proc(S, Watcher, {TName, TNode}, {TName, TNode});
        _ ->
            case {?TABLE_GET(PT, {node, FromNode}), ?TABLE_GET(PT, {node, TNode})} of
                {{_, {online, _}}, {_, {online, _}}} ->
                    ctl_monitor_proc(S, Watcher, {TName, TNode}, {TName, TNode});
                {{_, {offline, _}}, _} when TNode =:= ?LOCAL_NODE_NAME ->
                    ctl_monitor_proc(S, Watcher, {TName, FromNode}, {TName, TNode});
                _ ->
                    {S, badarg}
            end
    end;
ctl_handle_call(S, _Where, ?cci_process_monitor(Watcher, [], Target)) ->
    ctl_monitor_proc(S, Watcher, Target, Target);
ctl_handle_call(#sandbox_state{proc_table = PT} = S,
                _Where, ?cci_process_demonitor(Proc, Ref, Opts)) ->
    case ?TABLE_GET(PT, {monitor, Ref}) of
        {_, {Watcher, Target, _Object}} ->
            {{_, MList}, {_, WList}} =
                {?TABLE_GET(PT, {watching, Watcher}), ?TABLE_GET(PT, {monitored_by, Target})},
            PT0 = ?TABLE_REMOVE(PT, {monitor, Ref}),
            PT1 = ?TABLE_SET(PT0, {watching, Watcher}, lists:keydelete(Ref, 1, MList)),
            PT2 = ?TABLE_SET(PT1, {monitored_by, Target}, lists:keydelete(Ref, 1, WList)),
            {S#sandbox_state{proc_table = PT2}, true};
        undefined ->
            case lists:member(flush, Opts) of
                true ->
                    {_, MsgQueue} = ?TABLE_GET(PT, {msg_queue, Proc}),
                    {_, Match} =
                        lists:foldl(
                          fun (M, {Counter, Result}) ->
                                  case M of
                                      {'DOWN', Ref, _, _, _} -> {Counter + 1, {found, Counter + 1}};
                                      _ -> {Counter + 1, Result}
                                  end
                          end,
                          {0, not_found}, MsgQueue),
                    case Match of
                        not_found ->
                            %% according to documentation
                            {S, true};
                        {found, Pos} ->
                            {_, NewMsgQueue} = ?H:take_nth(Pos, MsgQueue),
                            PT0 = ?TABLE_SET(PT, {msg_queue, Proc}, NewMsgQueue),
                            {S#sandbox_state{proc_table = PT0}, not lists:member(info, Opts)}
                    end;
                false ->
                    {S, not lists:member(info, Opts)}
            end
    end;
ctl_handle_call(#sandbox_state{proc_table = PT} = S,
                _Where, ?cci_process_set_trap_exit(Proc, On)) ->
    case ?TABLE_GET(PT, {proc, Proc}) of
        {_, {alive, Props}} ->
            Prev =
                case dict:find(trap_exit, Props) of
                    {ok, V} -> V;
                    error -> false
                end,
            {S#sandbox_state{
               proc_table = ?TABLE_SET(PT, {proc, Proc}, {alive, dict:store(trap_exit, On, Props)})},
             {prev, Prev}};
        {_, {tomb, _}} ->
            ?WARNING("process_set_trap_exit - zombie?", []),
            {S, noproc};
        undefined ->
            ?WARNING("process_set_trap_exit on external process", []),
            {S, noproc}
    end;
ctl_handle_call(#sandbox_state{proc_table = PT} = S,
                _Where, ?cci_register_process(Node, Name, Proc)) ->
    case ?TABLE_GET(PT, {name, Proc}) of
        {_, {Node, []}} ->
            case ?TABLE_GET(PT, {reg, Node, Name}) of
                {_, _} ->
                    {S, badarg};
                undefined ->
                    PT0 = ?TABLE_SET(PT, {reg, Node, Name}, {proc, Proc}),
                    PT1 = ?TABLE_SET(PT0, {name, Proc}, {Node, Name}),
                    {S#sandbox_state{proc_table = PT1}, true}
            end;
        {_, {Node, _OtherName}} ->
            ?WARNING("Already registered process", []),
            {S, badarg};
        {_, {_OtherNode, _}} ->
            ?WARNING("Register remote process", []),
            {S, badarg};
        undefined ->
            ?WARNING("Cannot find process info", []),
            {S, badarg}
    end;
ctl_handle_call(#sandbox_state{proc_table = PT} = S,
                _Where, ?cci_register_external_process(Node, Name, Proc)) ->
    case ?TABLE_GET(PT, {reg, Node, Name}) of
        {_, _} ->
            {S, badarg};
        undefined ->
            PT0 = ?TABLE_SET(PT, {reg, Node, Name}, {external_proc, Proc}),
            PT1 = ?TABLE_SET(PT0, {external_proc, Proc}, {Node, Name}),
            {S#sandbox_state{proc_table = PT1}, true}
    end;
ctl_handle_call(#sandbox_state{proc_table = PT} = S,
                _Where, ?cci_unregister(Node, Name)) ->
    case ?TABLE_GET(PT, {reg, Node, Name}) of
        {_, {proc, Proc}} ->
            PT0 = case ?TABLE_GET(PT, {name, Proc}) of
                      {_, {Node, Name}} ->
                          ?TABLE_SET(PT, {name, Proc}, {Node, []})
                  end,
            {S#sandbox_state{proc_table = ?TABLE_REMOVE(PT0, {reg, Node, Name})}, true};
        {_, {external_proc, _Proc}} ->
            {S#sandbox_state{proc_table = ?TABLE_REMOVE(PT, {reg, Node, Name})}, true};
        {_, {port_agent, _Proc}} ->
            {S#sandbox_state{proc_table = ?TABLE_REMOVE(PT, {reg, Node, Name})}, true};
        undefined ->
            {S, badarg}
    end;
ctl_handle_call(#sandbox_state{proc_table = PT} = S,
                _Where, ?cci_whereis(FromNode, Node, Name)) ->
    Node0 =
        case FromNode of
            [] -> Node;
            _ ->
                case ?TABLE_GET(PT, {node, FromNode}) of
                    {_, {online, _}} -> Node;
                    {_, {offline, _}}
                      when Node =:= ?LOCAL_NODE_NAME ->
                        FromNode;
                    _ -> []
                end
        end,
    case ?TABLE_GET(PT, {reg, Node0, Name}) of
        {_, R} ->
            {S, R};
        undefined ->
            {S, undefined}
    end;
ctl_handle_call(#sandbox_state{ opt = _Opt
                              , abs_id_table = _AIDT
                              , proc_table = PT
                              , proc_shtable = SHT
                              , alive_counter = AC} = S,
                _Where, ?cci_process_receive(Proc, PatFun, Timeout)) ->
    Ref = make_ref(),
    case ?SHTABLE_GET(SHT, {exit, Proc}) of
        undefined ->
            PatFun0 = case PatFun of
                          undefined -> fun (_) -> false end;
                          _ -> PatFun
                      end,
            {_, MsgQueue} = ?TABLE_GET(PT, {msg_queue, Proc}),
            {_, Match} =
                %% Finding match from left to right, but later match will override -- this is for finding the index of the rightest match
                lists:foldl(
                  fun (M, {Counter, Result}) ->
                          case PatFun0(M) of
                              true -> {Counter + 1, {found, Counter + 1}};
                              false -> {Counter + 1, Result}
                          end
                  end,
                  {0, not_found}, MsgQueue),
            case Match of
                not_found ->
                    case Timeout of
                        0 ->
                            Proc ! {Ref, timeout},
                            {S, Ref};
                        infinity ->
                            PT0 = ?TABLE_SET(PT, {receive_status, Proc}, {Ref, PatFun0, infinity}),
                            {S#sandbox_state{proc_table = PT0, 
                                             alive = S#sandbox_state.alive -- [Proc],
                                             alive_counter = AC - 1}, Ref};
                        _ when is_integer(Timeout), Timeout > 0 ->
                            #sandbox_state{vclock = Clock, timeouts = Timeouts, timeouts_counter = TimeoutsC} = S,
                            Deadline = Clock + Timeout,
                            if
                                S#sandbox_state.opt#sandbox_opt.control_timeouts,
                                Deadline >= S#sandbox_state.vclock_limit ->
                                    PT0 = ?TABLE_SET(PT, {receive_status, Proc}, {Ref, PatFun0, infinity}),
                                    {S#sandbox_state{proc_table = PT0,
                                                     alive = S#sandbox_state.alive -- [Proc],
                                                     alive_counter = AC - 1}, Ref};
                                true ->
                                    S1 =
                                        case S#sandbox_state.opt#sandbox_opt.control_timeouts of
                                            true ->
                                                S#sandbox_state{
                                                  timeouts = [#timeout_entry{
                                                                 type = receive_timeout,
                                                                 proc = Proc, ref = Ref,
                                                                 vclock = Deadline}
                                                              | Timeouts]};
                                            false ->
                                                erlang:send_after(Timeout, self(), {cast, {receive_timeout, Proc, Ref}}),
                                                S
                                        end,
                                    PT0 = ?TABLE_SET(PT, {receive_status, Proc}, {Ref, PatFun0, Deadline}),
                                    {S1#sandbox_state{proc_table = PT0, 
                                                      alive = S#sandbox_state.alive -- [Proc], alive_counter = AC - 1,
                                                      timeouts_counter = TimeoutsC + 1}, Ref}
                            end
                    end;
                {found, Pos} ->
                    {M, NewMsgQueue} = ?H:take_nth(Pos, MsgQueue),
                    PT0 = ?TABLE_SET(PT, {msg_queue, Proc}, NewMsgQueue),
                    Proc ! {Ref, [message | M]},
                    {S#sandbox_state{proc_table = PT0}, Ref}
            end;
        _ ->
            Proc ! {Ref, signal},
            {S, Ref}
    end;
ctl_handle_call(S, Where, ?cci_send_msg(From, To, M)) ->
    ctl_process_send(S, Where, From, To, M);
ctl_handle_call(#sandbox_state{proc_table = PT} = S,
                _Where, ?cci_process_info(Proc, Props)) ->
    Ret =
        case ?TABLE_GET(PT, {proc, Proc}) of
            {_, {alive, _}} ->
                lists:foldr(fun (registered_name, Acc) ->
                                    R = case ?TABLE_GET(PT, {name, Proc}) of
                                            {_, {_Node, Name}} ->
                                                Name
                                        end,
                                    [{registered_name, R} | Acc];
                                (monitors, Acc) ->
                                    R = case ?TABLE_GET(PT, {watching, Proc}) of
                                            {_, WList} ->
                                                lists:foldr(fun ({_Ref, PID}, InAcc) ->
                                                                    [{process, PID} | InAcc]
                                                            end, [], WList)
                                        end,
                                    [{monitors, R} | Acc];
                                (monitored_by, Acc) ->
                                    R = case ?TABLE_GET(PT, {monitored_by, Proc}) of
                                            {_, MList} ->
                                                lists:foldr(fun ({_Ref, PID, _Object}, InAcc) ->
                                                                    [PID | InAcc]
                                                            end, [], MList)
                                        end,
                                    [{monitored_by, R} | Acc];
                                (message_queue_len, Acc) ->
                                    R = case ?TABLE_GET(PT, {msg_queue, Proc}) of
                                            {_, MsgList} ->
                                                length(MsgList)
                                        end,
                                    [{message_queue_len, R} | Acc];
                                (messages, Acc) ->
                                    R = case ?TABLE_GET(PT, {msg_queue, Proc}) of
                                            {_, MsgQueue} ->
                                                lists:reverse(MsgQueue)
                                        end,
                                    [{messages, R} | Acc];
                                (links, Acc) ->
                                    %% XXX handle external links?
                                    R = case ?TABLE_GET(PT, {linking, Proc}) of
                                            {_, LList} ->
                                                LList
                                        end,
                                    [{links, R} | Acc];
                                (dictionary, Acc) ->
                                    {dictionary, R0} = erlang:process_info(Proc, dictionary),
                                    R =
                                        lists:foldr(
                                          fun({K, _} = KV, IAcc) ->
                                                  case ?IS_INTERNAL_PDK(K) of
                                                      true ->
                                                          IAcc;
                                                      false ->
                                                          [KV | IAcc]
                                                  end
                                          end, [], R0),
                                    [{dictionary, R} | Acc];
                                (Item, Acc) ->
                                    case erlang:process_info(Proc, Item) of
                                        undefined -> Acc;
                                        R -> [R | Acc]
                                    end
                            end, [], Props);
            _ -> undefined
        end,
    {S, Ret};
ctl_handle_call(#sandbox_state{proc_table = PT} = S,
                _Where, ?cci_is_process_alive(Proc)) ->
    case ?TABLE_GET(PT, {proc, Proc}) of
        undefined ->
            {S, erlang:is_process_alive(Proc)};
        {_, {alive, _}} ->
            {S, true};
        {_, {tomb, _}} ->
            {S, false}
    end;
ctl_handle_call(#sandbox_state{proc_table = PT} = S,
                Where, ?cci_send_signal(From, Proc, Reason)) ->
    case ?TABLE_GET(PT, {proc, Proc}) of
        {_, {alive, Props}} ->
            case Reason =/= kill andalso dict:find(trap_exit, Props) of
                {ok, true} ->
                    {NextS, ok} = ctl_process_send(S, Where, From, Proc, {'EXIT', From, Reason}),
                    {NextS, true};
                _ when Reason =/= normal ->
                    {NextS, ok} = ctl_process_send_signal(S, Where, From, Proc, Reason),
                    {NextS, true};
                _ ->
                    {S, true}
            end;
        _ ->
            {S, true}
    end;
ctl_handle_call(#sandbox_state{proc_table = PT} = S,
                _Where, ?cci_process_on_exit(Proc, Reason)) ->
    case ?TABLE_GET(PT, {proc, Proc}) of
        {_, {alive, _Props}} ->
            unlink(Proc),
            {_, {Node, Name}} = ?TABLE_GET(PT, {name, Proc}),
            {_, WList} = ?TABLE_GET(PT, {watching, Proc}),
            {_, MList} = ?TABLE_GET(PT, {monitored_by, Proc}),
            {_, LList} = ?TABLE_GET(PT, {linking, Proc}),
            {_, PList} = ?TABLE_GET(PT, {node_procs, Node}),
            PT0 = ?TABLE_SET(?TABLE_SET(?TABLE_REMOVE(?TABLE_REMOVE(PT, {msg_queue, Proc}), {name, Proc}),
                                        {proc, Proc}, {tomb, Node}),
                             {node_procs, Node}, PList -- [Proc]),
            PT1 = case ?TABLE_GET(PT, deadprocs) of
                      undefined ->
                          ?TABLE_SET(PT0, deadprocs, Proc);
                      {_, DPList} ->
                          ?TABLE_SET(PT0, deadprocs, [Proc | DPList])
                  end,
            PTAfterBasic = case Name of
                               undefined ->
                                   PT1;
                               _ ->
                                   ?TABLE_REMOVE(PT1, {reg, Node, Name})
                           end,
            PT2 = lists:foldl(fun ({Ref, Target}, CurPT) ->
                                      {_, TML} = ?TABLE_GET(CurPT, {monitored_by, Target}),
                                      ?TABLE_SET(?TABLE_REMOVE(CurPT, {monitor, Ref}), {monitored_by, Target}, lists:keydelete(Ref, 1, TML))
                              end, ?TABLE_REMOVE(PTAfterBasic, {watching, Proc}), WList),
            {PTAfterMonitor, NotifyWatcherList} =
                lists:foldl(fun ({Ref, Watcher, Object}, {CurPT, L}) ->
                                    {_, TML} = ?TABLE_GET(CurPT, {watching, Watcher}),
                                    NextPT = ?TABLE_SET(?TABLE_REMOVE(CurPT, {monitor, Ref}), {watching, Watcher}, lists:keydelete(Ref, 1, TML)),
                                    {NextPT, [{Ref, Watcher, Object} | L]}
                            end, {?TABLE_REMOVE(PT2, {monitored_by, Proc}), []}, MList),
            {PTAfterLink, NotifyLinkList} =
                lists:foldl(fun (Linked, {CurPT, L}) ->
                                    {_, TML} = ?TABLE_GET(CurPT, {linking, Linked}),
                                    CurPT0 = ?TABLE_SET(CurPT, {linking, Linked}, TML -- [Proc]),
                                    CurPT1 = ?TABLE_REMOVE(CurPT0, {link, Linked, Proc}),
                                    CurPT2 = ?TABLE_REMOVE(CurPT1, {link, Proc, Linked}),
                                    {CurPT2, [Linked | L]}
                            end, {?TABLE_REMOVE(PTAfterMonitor, {linking, Proc}), []}, LList),
            PTFinal = PTAfterLink,
            ?DEBUG("process_exit ~p watchers = ~p, linked = ~p", [Proc, NotifyWatcherList, NotifyLinkList]),
            S0 = S#sandbox_state{proc_table = PTFinal},
            S1 = lists:foldl(fun ({Ref, Watcher, Object}, CurS) ->
                                     %% Take care of offline/online ...
                                     RealObject =
                                         case Object of
                                             {Name, ON} when ON =:= Node; ON =:= ?LOCAL_NODE_NAME ->
                                                 case ?TABLE_GET(CurS#sandbox_state.proc_table,
                                                                 {node, Node}) of
                                                     {_, {online, _}} ->
                                                         {Name, Node};
                                                     {_, {offline, _}} ->
                                                         Object
                                                 end;
                                             _ -> Object
                                         end,
                                     {NextS, ok} = ctl_process_send(CurS, exiting, Proc, Watcher,
                                                                    {'DOWN', Ref, process, RealObject,
                                                                     case Reason of
                                                                         kill -> killed;
                                                                         _ -> Reason
                                                                     end}),
                                     NextS
                             end,
                             S0, NotifyWatcherList),
            S2 = lists:foldl(fun (Linked, CurS) ->
                                     {_, {alive, LProps}} = ?TABLE_GET(PT, {proc, Linked}),
                                     case dict:find(trap_exit, LProps) of
                                         {ok, true} ->
                                             {NextS, ok} = ctl_process_send(CurS, exiting, Proc, Linked,
                                                                            {'EXIT', Proc,
                                                                             case Reason of
                                                                                 kill -> killed;
                                                                                 _ -> Reason
                                                                             end}),
                                             NextS;
                                         _ when Reason =/= normal ->
                                             {NextS, ok} = ctl_process_send_signal(CurS, exiting, Proc, Linked, Reason),
                                             NextS;
                                         _ ->
                                             CurS
                                     end
                             end,
                             S1, NotifyLinkList),
            %% Handle ets heir
            S3 = ctl_process_ets_on_exit(S2, Proc),
            #sandbox_state{transient_counter = TC, alive_counter = AC} = S3,
            {S3#sandbox_state{transient_counter = TC - 1,
                              alive = S3#sandbox_state.alive -- [Proc],
                              alive_counter = AC - 1}, ok};
        undefined ->
            ?WARNING("process_on_exit for unknown proc", []),
            {S, noproc}
    end;
ctl_handle_call(#sandbox_state{res_table = ResTable} = S,
                _Where, ?cci_resource_acquire(OpList)) ->
    {NewResTable, InfoAcc} =
        lists:foldr(
          fun ({ResType, Start, Size, OpType} = OpInfo, {CurResTable, InfoAcc}) ->
                  OList =
                      case dict:find(ResType, CurResTable) of
                          {ok, _Tree} ->
                              _Tree;
                          error ->
                              []
                      end,
                  HasRace =
                      lists:foldr(
                        fun ({_, OStart, OSize, OType}, false) ->
                                if
                                    OStart >= Start + Size ->
                                        false;
                                    Start >= OStart + OSize ->
                                        false;
                                    true ->
                                        OpType =:= write orelse OType =:= write
                                end;
                            (_, true) -> true
                        end, false, OList),
                  NewOList = [OpInfo | OList],
                  case HasRace of
                      false ->
                          {dict:store(ResType, NewOList, CurResTable), InfoAcc};
                      true ->
                          {dict:store(ResType, NewOList, CurResTable), [OpInfo | InfoAcc]}
                  end
          end, {ResTable, []}, OpList),
    {S#sandbox_state{res_table = NewResTable}, InfoAcc};
ctl_handle_call(#sandbox_state{res_table = ResTable} = S,
                _Where, ?cci_resource_release(OpList)) ->
    NewResTable =
        lists:foldr(
          fun ({ResType, _, _, _} = OpInfo, CurResTable) ->
                  {OList, Table0} = dict:take(ResType, CurResTable),
                  case OList -- [OpInfo] of
                      [] -> Table0;
                      NewOList ->
                          dict:store(ResType, NewOList, Table0)
                  end
          end, ResTable, OpList),
    {S#sandbox_state{res_table = NewResTable}, ok}.

ctl_process_ets_on_exit(#sandbox_state{proc_shtable = ShTab} = S, Proc) ->
    {S1, HandledList} =
        lists:foldr(
          fun ([_, _, Owner, _], {CurS, L}) when Owner =/= Proc ->
                  {CurS, L};
              %% below all ets are owned by Proc
              ([Ets, _, _, none], {CurS, L}) ->
                  ets:delete(Ets),
                  {CurS, [Ets | L]};
              ([Ets, VEts, _, {Heir, HeirData}], {CurS, L}) when Heir =/= Proc ->
                  HeirMsg = {'ETS-TRANSFER', VEts, Proc, HeirData},
                  ets:give_away(Ets, Heir, morpheus_internal),
                  {CurS0, ok} = ctl_process_send(CurS, exiting, Proc, Heir, HeirMsg),
                  {CurS0, [Ets | L]};
              (_, {CurS, L}) -> {CurS, L}
          end,
          {S, []},
          ets:match(ShTab, {{ets, '$1'}, {'$2', '$3', '$4'}})),
    %% Clean up all handled entry
    lists:foreach(fun (Ets) ->
                          ?SHTABLE_REMOVE(ShTab, {ets, Ets})
                  end, HandledList),
    S1.

ctl_monitor_proc(#sandbox_state{proc_table = PT} = S,
                 Watcher, {Name, Node}, Object) ->
    case ?TABLE_GET(PT, {reg, Node, Name}) of
        {_, {proc, Target}} ->
            ctl_monitor_proc(S, Watcher, Target, Object);
        _ ->
            Ref = make_ref(),
            %% Offline/online won't change since the Object passed in,
            %% so no translation here
            {S0, ok} = ctl_process_send(S, undefined, system, Watcher, {'DOWN', Ref, process, Object, noproc}),
            {S0, Ref}
    end;
ctl_monitor_proc(#sandbox_state{proc_table = PT} = S,
                 Watcher, Target, Object) ->
    case {?TABLE_GET(PT, {watching, Watcher}), ?TABLE_GET(PT, {monitored_by, Target})} of
        {{_, MList}, {_, WList}} ->
            Ref = make_ref(),
            PT0 =
                ?TABLE_SET(?TABLE_SET(PT, {watching, Watcher}, [{Ref, Target} | MList]),
                           {monitored_by, Target}, [{Ref, Watcher, Object} | WList]),
            PT1 = ?TABLE_SET(PT0, {monitor, Ref}, {Watcher, Target, Object}),
            {S#sandbox_state{proc_table = PT1}, Ref};
        _Other ->
            ToNotify =
                case ?TABLE_GET(PT, {external_proc, Target}) of
                    {_, _} ->
                        ?WARNING("Ignore monitors on external proc ~p", [Target]),
                        false;
                    _ ->
                        case {?TABLE_GET(PT, {proc, Watcher}), ?TABLE_GET(PT, {proc, Target})} of
                            {{_, {alive, _}}, {_, {tomb, _}}} ->
                                ok;
                            {{_, {tomb, _}}, _} ->
                                ?ERROR("process_monitor - zombie??", []);
                            Other ->
                                ?WARNING("Unhandled process_monitor ~p", [Other])
                        end,
                        true
                end,
            case ToNotify of
                true ->
                    Ref = make_ref(),
                    {S0, ok} = ctl_process_send(S, undefined, system, Watcher, {'DOWN', Ref, process, Object, noproc}),
                    {S0, Ref};
                false ->
                    Ref = make_ref(),
                    {S, Ref}
            end
    end.

ctl_handle_cast( #sandbox_state{ proc_table = PT
                               , alive_counter = AC
                               , timeouts_counter = TimeoutsC
                               , vclock = Clock} = S
               , {receive_timeout, Proc, Ref}) ->
    case ?TABLE_GET(PT, {receive_status, Proc}) of
        {_, {Ref, _PatFun, Timeout}} ->
            Proc ! {Ref, timeout},
            S#sandbox_state{
              proc_table = ?TABLE_REMOVE(PT, {receive_status, Proc}),
              alive = [Proc | S#sandbox_state.alive],
              alive_counter = AC + 1,
              timeouts_counter = TimeoutsC - 1,
              vclock = if
                           Clock < Timeout ->
                               Timeout;
                           true -> Clock
                       end
             };
        _ ->
            %% nothing needs done as receive is already passed
            S
    end;
ctl_handle_cast( #sandbox_state{ opt = #sandbox_opt{ time_uncertainty = TUC }
                               , proc_table = PT
                               , abs_id_table = AIDT
                               , vclock = Clock
                               , timeouts = TO} = S
               , {kick_timeouts}) ->
    case TO of
        [] ->
            ?WARNING("kicking empty timeouts?", []),
            S;
        _ ->
            %% Also do cleanup
            {AdvClock0, ValidTO} =
                lists:foldr(fun ( #timeout_entry{proc = Proc, ref = Ref, vclock = VC} = Cur
                                , {AdvClock, NewTO} = Acc) ->
                                    case ?TABLE_GET(PT, {receive_status, Proc}) of
                                        {_, {Ref, _, _}} ->
                                            if
                                                VC < Clock ->
                                                    {AdvClock, [Cur | NewTO]};
                                                AdvClock =:= undefined; VC =< AdvClock ->
                                                    {VC, [Cur | NewTO]};
                                                true ->
                                                    {AdvClock, [Cur | NewTO]}
                                            end;
                                        _ ->
                                            Acc
                                    end
                            end, {undefined, []}, TO),
            AdvClock = case AdvClock0 of undefined -> Clock; _ -> AdvClock0 end,
            {ToFire, NewTO} =
                lists:foldr(fun ( #timeout_entry{vclock = VC} = Cur
                                , {ToFire, NewTO}) ->
                                    if
                                        VC =< AdvClock + TUC ->
                                            {[Cur | ToFire], NewTO};
                                        true ->
                                            {ToFire, [Cur | NewTO]}
                                    end
                            end, {[], []}, ValidTO),
            %% ?INFO("kick timeout ~p ~p", [ToFire, NewTO]),
            S0 = S#sandbox_state{timeouts = NewTO},
            S1 = lists:foldr(
                   fun (#timeout_entry{ref = Ref, proc = Proc}, CurS) ->
                           case dict:find(Proc, AIDT) of
                               {ok, Aid} ->
                                   ctl_push_request_to_buffer(
                                     CurS, kick_timeout, Aid, timeout, make_ref(), {receive_timeout, Proc, Ref})
                           end
                   end, S0, ToFire),
            S1
    end;
ctl_handle_cast(#sandbox_state{undet_signals = _UndetSigs, undet_kick = KickRef} = S, {timeout, TRef, {undet_kick}}) ->
    case TRef of
        KickRef ->
            S#sandbox_state{undet_signals = 0};
        _ ->
            %% stale timer
            S
    end.

ctl_process_send( #sandbox_state
                  { opt = #sandbox_opt{trace_send = Verbose} = Opt
                  , proc_table = PT
                  , proc_shtable = SHT
                  , alive_counter = AC} = S
                , Where, From, Proc, Msg) ->
    {S0, R, I} =
        case ?TABLE_GET(PT, {msg_queue, Proc}) of
            undefined ->
                case ?TABLE_GET(PT, {proc, Proc}) of
                    {_, {tomb, _}} ->
                        {S, ok, send_to_tomb};
                    undefined ->
                        case {?TABLE_GET(PT, {external_proc, Proc}), ?TABLE_GET(PT, {port_agent, Proc})} of
                            {undefined, undefined} ->
                                ?INFO("ignored msg to unknown process ~p", [Proc]),
                                {S, external, ignored};
                            _ ->
                                Proc ! Msg,
                                {S, ok, external}
                        end
                end;
            {_, MsgQueue} ->
                case ?TABLE_GET(PT, {receive_status, Proc}) of
                    undefined ->
                        {S#sandbox_state{proc_table = ?TABLE_SET(PT, {msg_queue, Proc}, [Msg | MsgQueue])}, ok, queued};
                    {_, {Ref, PatFun, _Timeout}} ->
                        case PatFun(Msg) of
                            true ->
                                Proc ! {Ref, [message | Msg]},
                                case _Timeout of
                                    infinity ->
                                        {S#sandbox_state{proc_table = ?TABLE_REMOVE(PT, {receive_status, Proc}),
                                                         alive = [Proc | S#sandbox_state.alive],
                                                         alive_counter = AC + 1}, ok, matched};
                                    _ ->
                                        #sandbox_state{timeouts_counter = TimeoutsC} = S,
                                        {S#sandbox_state{proc_table = ?TABLE_REMOVE(PT, {receive_status, Proc}),
                                                         alive = [Proc | S#sandbox_state.alive],
                                                         alive_counter = AC + 1,
                                                         timeouts_counter = TimeoutsC - 1}, ok, matched}
                                end;
                            false ->
                                NewQueue = [Msg | MsgQueue],
                                if
                                    %% XXX make this check configurable
                                    length(NewQueue) > 100 ->
                                        ?WARNING("Message queue of ~w exceeds 100, maybe leakage?", [Proc]);
                                    true -> ok
                                end,
                                {S#sandbox_state{proc_table = ?TABLE_SET(PT, {msg_queue, Proc}, NewQueue)}, ok, not_match_queued}
                        end
                end
        end,
    case Verbose of
        true ->
            case ?SHTABLE_GET(SHT, tracing) of
                {_, true} ->
                    ctl_trace_send(Opt, SHT, Where, From, Proc, message, Msg, I);
                _ ->
                    ok
            end;
        false -> ok
    end,
    {S0, R}.

ctl_process_send_signal( #sandbox_state
                         { opt = #sandbox_opt{trace_send = Verbose} = Opt
                         , proc_table = PT
                         , proc_shtable = SHT
                         , alive_counter = AC} = S
                       , Where, From, Proc, Reason) ->
    case Verbose of
        true ->
            case ?SHTABLE_GET(SHT, tracing) of
                {_, true} ->
                    ctl_trace_send(Opt, SHT, Where, From, Proc, signal, Reason, sent);
                _ -> ok
            end;
        false -> ok
    end,
    ?SHTABLE_SET(SHT, {exit, Proc}, Reason),
    case ?TABLE_GET(PT, {msg_queue, Proc}) of
        undefined ->
            {S, external_or_dead};
        {_, _MsgQueue} ->
            case ?TABLE_GET(PT, {receive_status, Proc}) of
                undefined ->
                    %% signal will be handled once back to `handle`
                    {S, ok};
                {_, {Ref, _PatFun, _Timeout}} ->
                    Proc ! {Ref, signal},
                    case _Timeout of
                        infinity ->
                            {S#sandbox_state{proc_table = ?TABLE_REMOVE(PT, {receive_status, Proc}),
                                             alive = [Proc | S#sandbox_state.alive],
                                             alive_counter = AC + 1}, ok};
                        _ ->
                            #sandbox_state{timeouts_counter = TimeoutsC} = S,
                            {S#sandbox_state{proc_table = ?TABLE_REMOVE(PT, {receive_status, Proc}),
                                             alive = [Proc | S#sandbox_state.alive],
                                             alive_counter = AC + 1, timeouts_counter = TimeoutsC - 1}, ok}
                    end
            end
    end.

ctl_exit(#sandbox_state{mod_table = MT, proc_table = PT} = S, Reason) ->
    case Reason of
        normal ->
            ok;
        _ ->
            ?INFO( "ctl cast stop with reason ~p", [Reason])
    end,
    ?TABLE_FOLD(MT,
                fun ({Old, {New, _Nifs}}, _) ->
                        case New of
                            Old ->
                                %% This module has been skipped for instrumentation
                                ok;
                            _ ->
                                code:delete(New),
                                case code:soft_purge(New) of
                                    true ->
                                        ok;
                                    false ->
                                        ?DEBUG("~w: some processes are lingering while exiting sandbox. Forcely purging ~p(~p) ...", [?MODULE, Old, New]),
                                        code:purge(New),
                                        ok
                                end
                        end
                end, undefined),
    {Lives, Deads} =
        ?TABLE_FOLD(PT,
                    fun ({{proc, Proc}, {alive, _}}, {L, D}) ->
                            exit(Proc, kill), {L + 1, D};
                        ({{proc, Proc}, {tomb, _}}, {L, D}) ->
                            exit(Proc, kill), {L, D + 1};
                        (_, Acc) ->
                            Acc
                    end, {0, 0}),
    ets:delete(MT),
    ets:delete(PT),
    ?INFO("ctl stop transient = ~p, lives = ~p, deads = ~p", [S#sandbox_state.transient_counter, Lives, Deads]),
    #sandbox_state{opt = #sandbox_opt{fd_opts = FdOpts}} = S,
    case FdOpts of
        undefined ->
            ok;
        _ ->
            firedrill:stop()
    end,
    exit(Reason).

%% instrumentation callbacks - called by morpheus_instrument

to_handle(S, _Old, _New, {call, _, _, _}) ->
    {true, S}.

is_undet_nif(#sandbox_state{undet_nifs = UN}, M, F, A) ->
    lists:any(fun ({EM, EF, EA}) -> (EM =:= M) andalso (EF =:= F) andalso (EA =:= A);
                  ({EM, EF}) -> (EM =:= M) andalso (EF =:= F);
                  ({EM}) -> (EM =:= M);
                  (EM) when is_atom(EM) -> (EM =:= M)
              end, UN).

%% Hack
to_override(_, erl_eval, receive_clauses, 7) -> {true, callback};
%% Hack - redirect os time api to erlang time api
to_override(_, os, timestamp, 0) -> {true, callback};
to_override(_, os, system_time, 0) -> {true, callback};
to_override(_, os, system_time, 1) -> {true, callback};
%% Regular case
to_override(#sandbox_state{opt = #sandbox_opt{aux_module = Aux}}, M, F, A) ->
    Aux =/= undefined andalso erlang:function_exported(Aux, to_override, 3) andalso Aux:to_override(M, F, A).

%% Hack
to_expose(_, erl_eval, exprs, 5) -> true;
to_expose(_, _, _, _) ->
    false.

%% Runtime callbacks - only called in instrumented processes
%% There is only one exception: `instrumented_process_created/2`, which can be called in `spawn_instrumented/5`

handle(Old, New, Tag, Args, Ann) ->
    handle_signals(Ann),
    #sandbox_opt{verbose_handle = Verbose, aux_module = Aux} =
        Opt = get_opt(),
    case Verbose of
        true ->
            case ?SHTABLE_GET(get_shtab(), tracing) of
                {_, true} ->
                    ?INFO("~p ~p handle: ~w~n  ~p", [self(), Ann, Tag, Args]);
                _ ->
                    ok
            end;
        _ -> ok
    end,
    case Aux =/= undefined
        andalso erlang:function_exported(Aux, to_delay_call, 4)
        andalso Tag =:= call
         of
        true ->
            apply(fun (M, F, A) ->
                          case Aux:to_delay_call(Old, M, F, A) of
                              true ->
                                  call_ctl(get_ctl(), Ann, {delay});
                              {true, Log} ->
                                  call_ctl(get_ctl(), Ann, {delay, {log, Log}});
                              false ->
                                  ok;
                              {false, Log} ->
                                  call_ctl(get_ctl(), Ann, {nodelay, {log, Log}})
                          end
                  end, Args);
        _ -> undefined
    end,
    case {Tag, Args} of
        %% Hacks use erlang time for os, which are nif stubs
        {override, [callback, timestamp, _, A]} when Old =:= os ->
            handle_erlang(timestamp, A, {Old, New, Ann});
        {override, [callback, system_time, _, A]} when Old =:= os ->
            handle_erlang(system_time, A, {Old, New, Ann});
        %% Hacks for erl_eval
        {override, [callback, receive_clauses, _, A]} when Old =:= erl_eval ->
            %% This is basically copied from erl_eval of otp-20
            apply(fun (T, Cs, TB, Bs, Lf, Ef, RBs) ->
                          PatFun = fun (M) -> erl_eval:match_clause(Cs, [M], Bs, Lf, Ef) =/= nomatch end,
                          {B, Bs1} =
                              case handle(Old, New, 'receive', [PatFun, T], Ann) of
                                  timeout -> TB;
                                  [message | Msg] ->
                                      erl_eval:match_clause(Cs, [Msg], Bs, Lf, Ef)
                              end,
                          apply(New, exprs, [B, Bs1, Lf, Ef, RBs])
                  end, A);
        %% general override handling
        {override, [trace, F, Orig, A]} ->
            case ?SHTABLE_GET(get_shtab(), tracing) of
                {_, true} ->
                    ?INFO("~w calls ~w:~w args:~n  ~p", [self(), Old, F, A]);
                _ ->
                    ok
            end,
            handle(Old, New, call, [Old, Orig, A], Ann);
        {override, [callback, F, Orig, A]} ->
            Aux:handle_override(Old, New, F, Orig, A, Ann);
        {undet_nif_stub, [F, A]} ->
            %% ?INFO("undet nif ~p:~p/~p", [Old, F, length(A)]),
            R = apply(Old, F, A),
            ?cc_undet(get_ctl(), Ann),
            R;
        {apply, [F, A]} ->
            case is_function(F) andalso erlang:fun_info(F, type) of
                {type, external} ->
                    {module, Mod} = erlang:fun_info(F, module),
                    {name, Name} = erlang:fun_info(F, name),
                    handle(Old, New, call, [Mod, Name, A], Ann);
                {type, local} ->
                    erlang:apply(F, A);
                Other ->
                    ?WARNING("Unhandled apply fun ~p info ~p", [F, Other]),
                    error(apply_bad_fun)
            end;
        {call, [erlang, F, A]} ->
            handle_erlang(F, A, {Old, New, Ann});
        {call, [init, F, A]} ->
            handle_init(F, A, {Old, New, Ann});
        {call, [io, F, A]} ->
            handle_io(F, A, {Old, New, Ann});
        {call, [file, F, A]} ->
            handle_file(F, A, {Old, New, Ann});
        {call, [ets, F, A]} ->
            handle_ets(F, A, {Old, New, Ann});
        %% {call, [error_logger, F, A]} ->
        %%     apply(error_logger, F, A);
        %% {call, [gen, call, [error_logger | Rest]]} ->
        %%     %% HACK for elixir
        %%     apply(gen, call, [error_logger | Rest]);
        {call, [user, F, _A]} when F =:= start; F =:= start_out ->
            %% HACK to skip re-creating user process - forwarding io_request to the real user process.
            %% XXX message from user may lead to non-determinism
            RealUser = erlang:whereis(user),
            {ok, true} = ?cc_register_external_process(get_ctl(), Ann, get_node(), user, RealUser),
            RealUser;
        {call, [logger_simple_h, changing_config, _A]} ->
            %% HACK - changing_config does not exist in logger_simple_h, but will be called in bootstrap process - just to workaround it.
            ok;
        {call, [net_kernel, monitor_nodes, _A]} ->
            %% HACK - we do not really emulate nodeup and nodedown events
            ok;
        {call, [prim_eval, 'receive', [_F, _T]]} ->
            %% XXX properly handle
            ?ERROR("prim_eval:receive is not properly handled! May cause false positives", []),
            timeout;
        %% hide ourselves (except morpheus_guest and morpheus_guest_helper)
        {call, [morpheus_guest, F, A]} ->
            apply(morpheus_guest_real, F, A);
        {call, [morpheus_guest_real, _F, _A]} ->
            ignored;
        {call, [morpheus_sandbox, _F, _A]} ->
            ignored;
        {call, [morpheus_instrument, _F, _A]} ->
            ignored;
        {call, [Old, F, A]} ->
            apply(New, F, A);
        {call, [M, F, A]} ->
            {M0, F0, A0} = rewrite_call(Ann, M, F, A),
            apply(M0, F0, A0);
        {'receive', [PatFun, Timeout]} ->
            if
                Timeout =:= infinity orelse (is_integer(Timeout) andalso Timeout >= 0) ->
                    ok;
                true ->
                    error(timeout_value)
            end,
            Ctl = get_ctl(),
            case call_ctl(Ctl, Ann, {undet_barrier}) of
                {ok, true} ->
                    handle_undet_message(Ctl, Ann),
                    handle_signals(Ann);
                {ok, false} ->
                    ok
            end,
            {ok, Ref} = ?cc_process_receive(Ctl, Ann, self(), PatFun, Timeout),
            R = handle_receive(Ctl, Ann, Ref),
            #sandbox_opt{trace_receive = TraceReceive} = Opt,
            ToTrace =
                case TraceReceive of
                    true ->
                        case ?SHTABLE_GET(get_shtab(), tracing) of
                            {_, true} ->
                                true;
                            _ ->
                                false
                        end;
                    false ->
                        false
                end,
            case R of
                signal ->
                    handle_signals(Ann);
                timeout ->
                    case ToTrace of
                        true ->
                            ctl_trace_receive(Opt, get_shtab(), Ann, self(), timeout, undefined);
                        _ -> ok
                    end,
                    timeout;
                [message | Msg] ->
                    case ToTrace of
                        true ->
                            ctl_trace_receive(Opt, get_shtab(), Ann, self(), message, Msg);
                        _ -> ok
                    end,
                    R
            end
    end.

rewrite_call(Where, M, F, A) ->
    Arity = length(A),
    case morpheus_instrument:whitelist_func(M, F, Arity) of
        true ->
            {M, F, A};
        false ->
            Ctl = get_ctl(),
            {ok, NewM, NewF} = get_instrumented_func(Ctl, Where, M, F, Arity),
            {NewM, NewF, A}
    end.

handle_undet_message(Ctl, Where) ->
    receive
        {'ETS-TRANSFER', _, _, morpheus_internal} ->
            %% ignore redundant internal give_away message
            handle_undet_message(Ctl, Where);
        M ->
            ?INFO("~p got external message before blocking:~n  ~p", [self(), M]),
            %% At this moment, undet timeout is off, and this process is considered alive.
            %% we do not need to use {undet, ...} request to activate it again
            ?cc_send_msg(Ctl, Where, undet, self(), M),
            handle_undet_message(Ctl, Where)
    after
        0 ->
            ok
    end.

handle_receive(Ctl, Where, Ref) ->
    receive
        {Ref, Resp} ->
            Resp;
        {'ETS-TRANSFER', _, _, morpheus_internal} ->
            %% ignore redundant internal give_away message
            handle_receive(Ctl, Where, Ref);
        M ->
            ?INFO("~p received external message while blocking:~n  ~p", [self(), M]),
            ?cc_undet_send_msg(Ctl, Where, undet, self(), M),
            handle_receive(Ctl, Where, Ref)
    end.

handle_signals(Where) ->
    ShTab = get_shtab(),
    case ?SHTABLE_GET(ShTab, {exit, self()}) of
        undefined ->
            ok;
        {_, Reason} ->
            Opt = #sandbox_opt{trace_receive = Verbose} = get_opt(),
            case Verbose of
                true ->
                    case ?SHTABLE_GET(ShTab, tracing) of
                        {_, true} ->
                            ctl_trace_receive(Opt, get_shtab(), [], self(), signal, undefined);
                        _ -> ok
                    end;
                _ -> ok
            end,
            before_tomb(),
            %% cannot throw exit since it may be caught by the guest ...
            ?DEBUG("~p get exit signal ~p", [self(), Reason]),
            ?SHTABLE_REMOVE(ShTab, {exit, self()}),
            ?cc_process_on_exit(get_ctl(), Where, self(), Reason),
            become_tomb()
    end.

get_instrumented_module_info(Ctl, Where, M) ->
    Dict =
        case get(?PDK_MOD_MAP) of
            undefined ->
                dict:new();
            _D -> _D
        end,
    {ToUpdate, NewM, Nifs} =
        case dict:find(M, Dict) of
            error ->
                {ok, {_NewM, _Nifs}} = ?cc_instrument_module(Ctl, Where, M),
                {true, _NewM, sets:from_list(_Nifs)};
            {ok, {_NewM, _Nifs}} ->
                {false, _NewM, _Nifs}
        end,
    case ToUpdate of
        true ->
            put(?PDK_MOD_MAP, dict:store(M, {NewM, Nifs}, Dict));
        false ->
            ok
    end,
    {ok, NewM, Nifs}.

get_instrumented_func(Ctl, Where, M, F, _A) ->
    {ok, NewM, _Nifs} = get_instrumented_module_info(Ctl, Where, M),
    {ok, NewM, F}.

instrumented_process_created(Ctl, Where, ShTab, Node, Proc) ->
    NewAbsId =
        case get(?PDK_ABS_ID) of
            undefined ->
                %% Initial process
                {pid, Node, []};
            {pid, _Node, PList} ->
                C = get(?PDK_CREATION_COUNT),
                put(?PDK_CREATION_COUNT, C + 1),
                {pid, Node, [C | PList]}
        end,
    ?SHTABLE_SET(ShTab, {abs_id, Proc}, NewAbsId),
    {ok, ok} = ?cc_instrumented_process_created(Ctl, Where, Node, Proc).

instrumented_process_kick(_Ctl, _Node, Proc) ->
    Proc ! start.

get_ctl() ->
    case get(?PDK_CTL) of
        undefined ->
            error(morpheus_guest, lists:flatten(io_lib:format("Failed to get sandbox ctl at ~p", [self()])));
        V -> V
    end.

get_node() ->
    case get(?PDK_NODE) of
        undefined ->
            error(morpheus_guest, lists:flatten(io_lib:format("Failed to get sandbox node at ~p", [self()])));
        V -> V
    end.

get_opt() ->
    case get(?PDK_OPT) of
        undefined ->
            error(morpheus_guest, lists:flatten(io_lib:format("Failed to get sandbox opt at ~p", [self()])));
        V -> V
    end.

get_shtab() ->
    case get(?PDK_SHTAB) of
        undefined ->
            error(morpheus_guest, lists:flatten(io_lib:format("Failed to get sandbox shtab at ~p", [self()])));
        V -> V
    end.

instrumented_process_start(Ctl, Node, Opt, ShTab) ->
    put(?PDK_CTL, Ctl),
    put(?PDK_NODE, Node),
    put(?PDK_OPT, Opt),
    put(?PDK_SHTAB, ShTab),
    receive start -> ok end,
    {_, AbsId} = ?SHTABLE_GET(ShTab, {abs_id, self()}),
    put(?PDK_ABS_ID, AbsId),
    put(?PDK_CREATION_COUNT, 0),
    ok.

instrumented_process_end(V) ->
    before_tomb(),
    case V of
        {ok, _Value} ->
            ?cc_process_on_exit(get_ctl(), process_exit, self(), normal);
        {exit, R, _} ->
            ?cc_process_on_exit(get_ctl(), process_exit, self(), R);
        {error, R, ST} ->
            ?WARNING("Process ~p abort with ~p", [self(), V]),
            ?cc_process_on_exit(get_ctl(), process_exit, self(), {R, ST});
        {throw, R, ST} ->
            ?WARNING("Process ~p abort with ~p", [self(), V]),
            ?cc_process_on_exit(get_ctl(), process_exit, self(), {{nocatch, R}, ST})
    end,
    become_tomb().

before_tomb() ->
    %% Give away all ets tables to ctl for atomic processing
    Me = self(),
    Ctl = get_ctl(),
    ShTab = get_shtab(),
    lists:foreach(fun (Ets) ->
                          Owner = ets:info(Ets, owner),
                          case Owner =:= self() of
                              true ->
                                  HeirInfo =
                                      case ?SHTABLE_GET(ShTab, {heir, Ets}) of
                                          undefined -> none;
                                          {_, _Info} ->
                                              ?SHTABLE_REMOVE(ShTab, {heir, Ets}),
                                              _Info
                                      end,
                                  VEts = if
                                             is_atom(Ets) ->
                                                 decode_ets_name(Ets);
                                             true -> Ets
                                         end,
                                  ?SHTABLE_SET(ShTab, {ets, Ets}, {VEts, Me, HeirInfo}),
                                  ets:give_away(Ets, Ctl, morpheus_internal);
                              false ->
                                  ok
                          end
                    end, ets:all()),
    ok.

%% erlang:hibernate seems not stable?
become_tomb() ->
    %% erlang:hibernate(?MODULE, tomb, []).
    receive
    after
        infinity ->
            ok
    end,
    error(zombie).

%% tomb() ->
%%     receive _ -> erlang:hibernate(?MODULE, tomb, []) after infinity -> error(zombie) end.

hibernate_entry(M, F, A) ->
    receive morpheus_internal_hibernate_wakeup -> ok end,
    instrumented_process_end(?CATCH(apply(M, F, A))).

%% sandboxed lib erlang handling

handle_erlang('!', [T, M], Aux) ->
    handle_erlang(send, [T, M], Aux);
handle_erlang(send, [Pid, M], {_Old, _New, Ann}) when is_pid(Pid) ->
    {ok, R} = ?cc_send_msg(get_ctl(), Ann, self(), Pid, M),
    case R of
        ok ->
            M;
        external ->
            ?WARNING("Ignored external message ~p to ~p", [M, Pid]),
            M
    end;
handle_erlang(send, [Pid, M, _Opts], Aux) when is_pid(Pid) ->
    %% options are ignored for now
    handle_erlang(send, [Pid, M], Aux),
    ok;
handle_erlang(send, [Name, Msg | Opts], {_Old, _New, Ann}) when is_atom(Name) ->
    {ok, Ret} = ?cc_whereis(get_ctl(), Ann, [], get_node(), Name),
    case Ret of
        {_, Pid} when is_pid(Pid) ->
            %% assume lookup and send is atomic (actually not in Beam VM)
            {ok, ok} = ?cc_nodelay_send_msg(get_ctl(), Ann, self(), Pid, Msg),
            case Opts of
                [] -> Msg;
                _ -> ok
            end;
            %% handle_erlang(send, [Pid, Msg | Opts], Aux);
        _ ->
            %% The only case to return error
            error(badarg)
    end;
handle_erlang(send, [{Name, Node}, Msg | Opts], {_Old, _New, Ann}) when is_atom(Node), is_atom(Name) ->
    {ok, Ret} = ?cc_whereis(get_ctl(), Ann, get_node(), Node, Name),
    case Ret of
        {_, Pid} when is_pid(Pid) ->
            %% assume lookup and send is atomic (actually not in Beam VM)
            {ok, ok} = ?cc_nodelay_send_msg(get_ctl(), Ann, self(), Pid, Msg),
            case Opts of
                [] -> Msg;
                _ -> ok
            end;
            %% handle_erlang(send, [Pid, Msg | Opts], Aux);
        _ ->
            case Opts of
                [] -> Msg;
                _ -> ok
            end
    end;
handle_erlang(send, _Args, _Aux) ->
    error(unhandled_send);
handle_erlang(send_nosuspend, A, _Aux) ->
    handle_erlang(send, A, _Aux);
%% time api
handle_erlang(start_timer, A, {Old, New, Ann}) ->
    handle(Old, New, call, [morpheus_guest_internal, start_timer, A], Ann);
handle_erlang(read_timer, A, {Old, New, Ann}) ->
    handle(Old, New, call, [morpheus_guest_internal, read_timer, A], Ann);
handle_erlang(cancel_timer, A, {Old, New, Ann}) ->
    handle(Old, New, call, [morpheus_guest_internal, cancel_timer, A], Ann);
handle_erlang(send_after, A, {Old, New, Ann}) ->
    handle(Old, New, call, [morpheus_guest_internal, send_after, A], Ann);
%% timestamp virtualization. We are also emulating the native time unit to be `millisecond`.
%% We hope this would be enough
handle_erlang(monotonic_time, A, {_Old, _New, Ann}) ->
    {ok, {Clock, _Offset}} = ?cc_get_clock(get_ctl(), Ann),
    case A of
        [] -> Clock;
        [native] -> Clock;
        [Unit] ->
            erlang:convert_time_unit(Clock, millisecond, Unit)
    end;
handle_erlang(system_time, A, {_Old, _New, Ann}) when length(A) =< 1 ->
    {ok, {Clock, Offset}} = ?cc_get_clock(get_ctl(), Ann),
    SClock = Clock + Offset,
    case A of
        [] -> SClock;
        [native] -> SClock;
        [Unit] ->
            erlang:convert_time_unit(SClock, millisecond, Unit)
    end;
handle_erlang(time_offset, A, {_Old, _New, Ann}) when length(A) =< 1 ->
    {ok, {_Clock, Offset}} = ?cc_get_clock(get_ctl(), Ann),
    case A of
        [] -> Offset;
        [native] -> Offset;
        [Unit] ->
            erlang:convert_time_unit(Offset, millisecond, Unit)
    end;
handle_erlang(timestamp, [], {_Old, _New, Ann}) ->
    {ok, {Clock, Offset}} = ?cc_get_clock(get_ctl(), Ann),
    SClock = Clock + Offset,
    MegaSecs = SClock div 1000000000,
    Secs = SClock div 1000 - MegaSecs * 1000000,
    MicroSecs = SClock rem 1000 * 1000,
    {MegaSecs, Secs, MicroSecs};
handle_erlang(now, [], Aux) ->
    handle_erlang(timestamp, [], Aux);
handle_erlang(convert_time_unit, [N, From, To], _Aux) ->
    NewFrom =
        case From of
            native -> millisecond;
            _ -> From
        end,
    NewTo =
        case To of
            native -> millisecond;
            _ -> To
        end,
    erlang:convert_time_unit(N, NewFrom, NewTo);
%% register/unregister/whereis
handle_erlang(register, [Name, Pid], {_Old, _New, Ann}) when is_atom(Name), is_pid(Pid) ->
    {ok, Ret} = ?cc_register_process(get_ctl(), Ann, get_node(), Name, Pid),
    case Ret of
        badarg -> error(badarg);
        _ -> Ret
    end;
handle_erlang(unregister, [Name], {_Old, _New, Ann}) when is_atom(Name) ->
    {ok, Ret} = ?cc_unregister(get_ctl(), Ann, get_node(), Name),
    case Ret of
        badarg -> error(badarg);
        _ -> Ret
    end;
handle_erlang(whereis, [Name], {_Old, _New, Ann}) when is_atom(Name) ->
    {ok, Ret} = ?cc_whereis(get_ctl(), Ann, [], get_node(), Name),
    case Ret of
        {_, Pid} ->
            Pid;
        undefined ->
            undefined
    end;
%% monitor
handle_erlang(monitor, [process, Pid], {_Old, _New, Ann}) when is_pid(Pid) ->
    {ok, Ref} = ?cc_process_monitor(get_ctl(), Ann, self(), [], Pid),
    case Ref of
        badarg -> error(badarg);
        _ -> Ref
    end;
handle_erlang(monitor, [process, Name], {_Old, _New, Ann}) when is_atom(Name) ->
    {ok, Ref} = ?cc_process_monitor(get_ctl(), Ann, self(), [], {Name, get_node()}),
    Ref;
handle_erlang(monitor, [process, {Name, Node}], {_Old, _New, Ann}) when is_atom(Name), is_atom(Node) ->
    {ok, Ref} = ?cc_process_monitor(get_ctl(), Ann, self(), get_node(), {Name, Node}),
    case Ref of
        badarg -> error(badarg);
        _ -> Ref
    end;
handle_erlang(monitor, [port, Port], _Aux) ->
    erlang:monitor(port, Port);
handle_erlang(monitor, [_OtherType, _Object], _Aux) ->
    ?ERROR("Unsupported monitor type ~p of ~p", [_OtherType, _Object]),
    make_ref();
%% demonitor
handle_erlang(demonitor, [Ref], {_Old, _New, Ann}) ->
    {ok, Ret} = ?cc_process_demonitor(get_ctl(), Ann, self(), Ref, []),
    Ret;
handle_erlang(demonitor, [Ref, Opts], {_Old, _New, Ann}) ->
    {ok, Ret} = ?cc_process_demonitor(get_ctl(), Ann, self(), Ref, Opts),
    Ret;
%% spawn
handle_erlang(spawn, Args, {_Old, _New, Ann}) ->
    apply(?MODULE, handle_erlang_spawn, [Ann, spawn | Args]);
handle_erlang(spawn_link, Args, {_Old, _New, Ann}) ->
    apply(?MODULE, handle_erlang_spawn, [Ann, spawn_link | Args]);
handle_erlang(spawn_monitor, Args, {_Old, _New, Ann}) ->
    apply(?MODULE, handle_erlang_spawn, [Ann, spawn_monitor | Args]);
handle_erlang(spawn_opt, Args, {_Old, _New, Ann}) ->
    apply(?MODULE, handle_erlang_spawn_opt, [Ann | Args]);
%% process_flag trap_exit
handle_erlang(process_flag, [trap_exit, On], {_Old, _New, Ann}) ->
    {ok, {prev, Prev}} = ?cc_process_set_trap_exit(get_ctl(), Ann, self(), On),
    Prev;
%% link
handle_erlang(link, [ProcOrPort], {_Old, _New, Ann}) ->
    Ret =
        if
            is_pid(ProcOrPort) ->
                case ?cc_process_link(get_ctl(), Ann, self(), ProcOrPort) of
                    {ok, noproc} ->
                        error(noproc);
                    {ok, badarg} ->
                        error(badarg);
                    {ok, InRet} ->
                        InRet
                end;
            is_port(ProcOrPort) ->
                link(ProcOrPort);
            true ->
                error(badarg)
        end,
    Ret;
%% misc
%% handle_erlang(get_stacktrace, [], _Aux) ->
%%     %% XXX clean up our stacks?
%%     erlang:get_stacktrace();
%% handle_erlang(throw, [ok], _Aux) ->
%%     Info = ?CATCH( throw(gimme_stacktrace) ),
%%     ?INFO("~p throw ok ~p", [self(), Info]),
%%     erlang:throw(ok);
%% exit
handle_erlang(exit, [Reason], _Aux) ->
    %% Info = ?CATCH( throw(gimme_stacktrace) ),
    %% ?INFO("~p call erlang exit at ~p", [self(), Info]),
    erlang:exit(Reason);
handle_erlang(exit, [Proc, Reason], {_Old, _New, Ann} = _Aux) ->
    Me = self(),
    case Proc of
        Me ->
            handle_erlang(exit, [Reason], _Aux);
        _ ->
            {ok, Ret} = ?cc_send_signal(get_ctl(), Ann, self(), Proc, Reason),
            Ret
    end;
%% unlink
handle_erlang(unlink, [ProcOrPort], {_Old, _New, Ann}) ->
    Ret =
    if
        is_pid(ProcOrPort) ->
            case ?cc_process_unlink(get_ctl(), Ann, self(), ProcOrPort) of
                {ok, badarg} ->
                    error(badarg);
                {ok, InRet} ->
                    InRet
            end;
        is_port(ProcOrPort) ->
            unlink(ProcOrPort);
        true ->
            error(badarg)
    end,
    Ret;
%% apply
handle_erlang(apply, [M, F, A], {Old, New, Ann}) ->
    morpheus_sandbox:handle(Old, New, call, [M, F, A], Ann);
handle_erlang(apply, [F, A], {Old, New, Ann}) ->
    Info = is_function(F) andalso erlang:fun_info(F, type),
    case Info of
        {type, external} ->
            {module, Mod} = erlang:fun_info(F, module),
            {name, Name} = erlang:fun_info(F, name),
            handle(Old, New, call, [Mod, Name, A], Ann);
        {type, local} ->
            erlang:apply(F, A);
        _ ->
            error(apply_bad_fun)
    end;
%% process_info
%% process_info virtualization is very limited now, as there are simply too many stuff ...
%% So far this is for running some tests (i.e. poolboy)
handle_erlang(process_info, [Pid, Prop], {_Old, _New, Ann}) when is_atom(Prop) ->
    {ok, Ret} = ?cc_process_info(get_ctl(), Ann, Pid, [Prop]),
    case Ret of
        [] ->
            undefined;
        undefined ->
            undefined;
        [{registered_name, []}] ->
            %% special case according to doc (until Ref Man 10.0)
            [];
        [ItemTuple] ->
            ItemTuple
    end;
handle_erlang(process_info, [Pid, PropList], {_Old, _New, Ann}) when is_list(PropList) ->
    {ok, Ret} = ?cc_process_info(get_ctl(), Ann, Pid, PropList),
    Ret;
handle_erlang(process_info, [Pid], {_Old, _New, Ann}) ->
    {ok, Ret} = ?cc_process_info(get_ctl(), Ann, Pid,
                                 %% all virtualized items that are supposed to return
                                 [registered_name,
                                  monitors,
                                  monitored_by,
                                  links,
                                  %% no need for messages, since it's not returned in this call
                                  message_queue_len]),
    Original = erlang:process_info(Pid),
    case Ret of
        undefined ->
            Original;
        _ ->
            lists:foldr(fun ({K, _V} = KV, Acc) ->
                                case proplists:lookup(K, Ret) of
                                    none ->
                                        [KV | Acc];
                                    {K, VRet} ->
                                        [{K, VRet} | Acc]
                                end
                        end, [], Original)
    end;
%% is_process_alive
handle_erlang(is_process_alive, [Pid], {_Old, _New, Ann}) when is_pid(Pid) ->
    {ok, Ret} = ?cc_is_process_alive(get_ctl(), Ann, Pid),
    Ret;
%% processes
handle_erlang(processes, [], {_Old, _New, Ann}) ->
    {ok, Ret} = ?cc_instrumented_process_list(get_ctl(), Ann, get_node()),
    Ret;
handle_erlang(registered, [], {_Old, _New, Ann}) ->
    {ok, Ret} = ?cc_instrumented_registered_list(get_ctl(), Ann, get_node()),
    Ret;
handle_erlang(erase, [], _Aux) ->
    %% Keep sandbox info after erase
    lists:foldr(fun ({K, V} = KV, R) ->
                        case ?IS_INTERNAL_PDK(K) of
                            true -> put(K, V), R;
                            _ -> [KV | R]
                        end
                end, [], erase());
%% always return positive and monotonic integers ...
handle_erlang(unique_integer, _Args, {_Old, _New, Ann}) ->
    {ok, I} = ?cc_unique_integer(get_ctl(), Ann),
    I;
%% hibernate
handle_erlang(hibernate, [M, F, A], {_Old, _New, Ann}) ->
    {M0, F0, A0} = rewrite_call(Ann, M, F, A),
    self() ! morpheus_internal_hibernate_wakeup,
    erlang:hibernate(?MODULE, hibernate_entry, [M0, F0, A0]);
%% HACK, this is for rand! hopefully we don't mess up other things
%% XXX only do this if the stack contains rand:seed_s?
handle_erlang(phash2, [Term], _Aux) ->
    MagicTerm = [{get_node(), self()}],
    case Term of
        MagicTerm ->
            erlang:phash2([{get_node()}]);
        _ ->
            erlang:phash2(Term)
    end;
handle_erlang(open_port, A, {_Old, _New, Ann}) ->
    R = apply(erlang, open_port, A),
    ?cc_undet(get_ctl(), Ann),
    R;
handle_erlang(port_command, A, {_Old, _New, Ann}) ->
    R = apply(erlang, port_command, A),
    ?cc_undet(get_ctl(), Ann),
    R;
handle_erlang(port_connect, A, {_Old, _New, Ann}) ->
    R = apply(erlang, port_connect, A),
    ?cc_undet(get_ctl(), Ann),
    R;
handle_erlang(port_control, A, {_Old, _New, Ann}) ->
    R = apply(erlang, port_control, A),
    ?cc_undet(get_ctl(), Ann),
    R;
handle_erlang(port_close, A, {_Old, _New, Ann}) ->
    R = apply(erlang, port_close, A),
    ?cc_undet(get_ctl(), Ann),
    R;
%% Cannot be global
handle_erlang(setnode, [Name, Creation], {_Old, _New, Ann}) ->
    ?INFO("called erlang:setnode(~p, ~p)", [Name, Creation]),
    MyNode = get_node(),
    case Name of
        ?LOCAL_NODE_NAME ->
            {ok, Ret} = call_ctl(get_ctl(), Ann, {node_set_alive, get_node(), false}),
            Ret;
        MyNode ->
            {ok, Ret} = call_ctl(get_ctl(), Ann, {node_set_alive, get_node(), true}),
            Ret;
        _ ->
            error(name_not_match)
    end;
%% ignored since we do not model node failure
handle_erlang(monitor_node, [_Node, _Flag], _Aux) ->
    true;
handle_erlang(monitor_node, [_Node, _Flag, _Options], _Aux) ->
    true;
%%
handle_erlang(nodes, [], Aux) ->
    handle_erlang(nodes, [visible], Aux);
handle_erlang(nodes, [L], {_Old, _New, Ann}) ->
    {ok, Ret} = ?cc_list_nodes(get_ctl(), Ann, get_node(), L),
    Ret;
%%
handle_erlang(node, [], _Aux) ->
    %% possible through apply(erlang, node, [])
    erlang:node(self());
%% other
handle_erlang(put, [K, V], _Aux) ->
    case ?IS_INTERNAL_PDK(K) of
        true ->
            ?ERROR("Guest trying to override internal pdk ~w. Ignored.", [K]),
            undefined;
        false ->
            erlang:put(K, V)
    end;
handle_erlang(get, [K], _Aux) ->
    case ?IS_INTERNAL_PDK(K) of
        true ->
            ?ERROR("Guest trying to get internal pdk ~w. Ignored.", [K]),
            undefined;
        false ->
            erlang:get(K)
    end;
handle_erlang(get, [], _Aux) ->
    lists:foldr(
      fun({K, _} = KV, Acc) ->
              case ?IS_INTERNAL_PDK(K) of
                  true ->
                      Acc;
                  false ->
                      [KV | Acc]
              end
      end, [], erlang:get());
handle_erlang(F, A, _Aux) ->
    apply(erlang, F, A).

handle_erlang_spawn(Where, S, F) ->
    Ctl = get_ctl(),
    Node = get_node(),
    Opt = get_opt(),
    ShTab = get_shtab(),
    Pid = spawn(fun () ->
                        instrumented_process_start(Ctl, Node, Opt, ShTab),
                        instrumented_process_end(?CATCH(F()))
                end),
    post_spawn(S, Ctl, Where, ShTab, Node, Pid).

handle_erlang_spawn(Where, S, Node, F) ->
    Ctl = get_ctl(),
    Opt = get_opt(),
    ShTab = get_shtab(),
    Pid = spawn(fun () ->
                        instrumented_process_start(Ctl, Node, Opt, ShTab),
                        instrumented_process_end(?CATCH(F()))
                end),
    post_spawn(S, Ctl, Where, ShTab, Node, Pid).

handle_erlang_spawn(Where, S, M, F, A) ->
    Ctl = get_ctl(),
    Node = get_node(),
    Opt = get_opt(),
    ShTab = get_shtab(),
    {ok, NewM, NewName} = get_instrumented_func(Ctl, Where, M, F, length(A)),
    case NewM of
        M ->
            ?WARNING("Trying to spwan a process with nif entry ~p - this may go wild!", [{M, F, A}]);
        _ -> ok
    end,
    Pid = spawn(fun () ->
                        instrumented_process_start(Ctl, Node, Opt, ShTab),
                        instrumented_process_end(?CATCH(apply(NewM, NewName, A)))
                end),
    post_spawn(S, Ctl, Where, ShTab, Node, Pid).

handle_erlang_spawn(Where, S, Node, M, F, A) ->
    Ctl = get_ctl(),
    Opt = get_opt(),
    ShTab = get_shtab(),
    {ok, NewM, NewName} = get_instrumented_func(Ctl, Where, M, F, length(A)),
    case NewM of
        M ->
            ?WARNING("Trying to spwan a process with nif entry ~p - this may go wild!", [{M, F, A}]);
        _ -> ok
    end,
    Pid = spawn(fun () ->
                        instrumented_process_start(Ctl, Node, Opt, ShTab),
                        instrumented_process_end(?CATCH(apply(NewM, NewName, A)))
                end),
    post_spawn(S, Ctl, Where, ShTab, Node, Pid).

post_spawn(S, Ctl, Where, ShTab, Node, Pid) ->
    instrumented_process_created(Ctl, Where, ShTab, Node, Pid),
    Ret =
        case S of
            spawn ->
                Pid;
            spawn_link ->
                call_ctl(Ctl, Where, {nodelay, ?cci_process_link(self(), Pid)}),
                Pid;
            spawn_monitor ->
                {ok, Ref} = call_ctl(Ctl, Where, {nodelay, ?cci_process_monitor(self(), [], Pid)}),
                {Pid, Ref};
            _ ->
                ?WARNING("Unhandled spawn type: ~p", S),
                Pid
        end,
    instrumented_process_kick(Ctl, Node, Pid),
    Ret.

handle_erlang_spawn_opt(Where, F, Opts) ->
    Ctl = get_ctl(),
    Node = get_node(),
    Opt = get_opt(),
    ShTab = get_shtab(),
    Pid = spawn(
            fun () ->
                    instrumented_process_start(Ctl, Node, Opt, ShTab),
                    instrumented_process_end(?CATCH(F()))
            end),
    post_spawn_opt(Ctl, Where, ShTab, Node, Pid, Opts).

handle_erlang_spawn_opt(Where, M, F, A, Opts) ->
    Ctl = get_ctl(),
    Node = get_node(),
    Opt = get_opt(),
    ShTab = get_shtab(),
    {ok, NewM, NewName} = get_instrumented_func(Ctl, Where, M, F, length(A)),
    case NewM of
        M ->
            ?WARNING("Trying to spwan a process with nif entry ~p - this may go wild!", [{M, F, A}]);
        _ -> ok
    end,
    Pid = spawn(
            fun () ->
                    instrumented_process_start(Ctl, Node, Opt, ShTab),
                    instrumented_process_end(?CATCH(apply(NewM, NewName, A)))
            end),
    post_spawn_opt(Ctl, Where, ShTab, Node, Pid, Opts).

post_spawn_opt(Ctl, Where, ShTab, Node, Pid, Opts) ->
    instrumented_process_created(Ctl, Where, ShTab, Node, Pid),
    case lists:member(link, Opts) of
        true ->
            call_ctl(Ctl, Where, {nodelay, ?cci_process_link(self(), Pid)});
        false -> ok
    end,
    Ret =
        case lists:member(monitor, Opts) of
            true ->
                {ok, Ref} = call_ctl(Ctl, Where, {nodelay, ?cci_process_monitor(self(), [], Pid)}),
                {Pid, Ref};
            _ ->
                Pid
        end,
    instrumented_process_kick(Ctl, Node, Pid),
    Ret.

%% sandboxed lib init handling

handle_init(F, A, Aux) ->
    case F of
        archive_extension ->
            apply(init, F, A);
        objfile_extension ->
            apply(init, F, A);
        get_argument ->
            case A of
                [epmd_module] ->
                    %% HACK, skip epmd communication
                    {ok, [["morpheus_sandbox_mock_epmd_module"]]};
                _ ->
                    apply(init, F, A)
            end;
        get_arguments ->
            apply(init, F, A);
        run_on_load_handlers ->
            apply(init, F, A);
        fetch_loaded ->
            apply(init, F, A);
        code_path_choice ->
            apply(init, F, A);
        _ ->
            ?WARNING("~p calling init:~p ~p~n", [Aux, F, A]),
            apply(init, F, A)
    end.

%% sandboxed lib io handling

handle_io(F, A, _Aux) ->
    case A of
        [standard_io | R] ->
            apply(io, F, [user | R]);
        [IODev | _] when is_pid(IODev); is_atom(IODev) ->
            apply(io, F, A);
        _ ->
            apply(io, F, [user | A])
    end.

detect_file_op_race(Where, IoDev, Start, Size, Type) ->
    IOList = [{{iodev, IoDev}, Start, Size, Type}],
    {ok, R} = ?cc_resource_acquire(get_ctl(), Where, IOList),
    case R of
        [] -> ok;
        _ ->
            {_, _, ST} = ?CATCH( throw(gimme_stacktrace) ),
            ?WARNING("Race on file operation found~nStack: ~p", [ST])
    end,
    {ok, ok} = ?cc_resource_release(get_ctl(), Where, IOList).

handle_file(F, A, {_Old, _New, Ann}) ->
    case F of
        pread when length(A) =:= 3 ->
            [IoDev, _Start, _Size] = A,
            detect_file_op_race(Ann, IoDev, 1, 1, read);
        pwrite when length(A) =:= 3 ->
            [IoDev, _Start, _Data] = A,
            detect_file_op_race(Ann, IoDev, 1, 1, write);
        read ->
            [IoDev, _Size] = A,
            {ok, _Start} = file:position(IoDev, cur),
            detect_file_op_race(Ann, IoDev, 1, 1, read);
        write ->
            [IoDev, _Data] = A,
            {ok, _Start} = file:position(IoDev, cur),
            detect_file_op_race(Ann, IoDev, 1, 1, write);
        _ -> ok
    end,
    apply(file, F, A).

%% sandboxed lib ets handling

handle_ets(F, A, {_Old, _New, Ann}) ->
    case F of
        all ->
            {ok, Ret} = ?cc_ets_all(get_ctl(), Ann),
            lists:map(fun (Name) ->
                        if
                            is_atom(Name) ->
                                decode_ets_name(Name);
                            true ->
                                Name
                        end
                      end, Ret);
        _ ->
            call_ctl(get_ctl(), Ann, {maybe_delay, {log, {ets_op, F, A}}}),
            %% essentially we are trying to virtualize the ets namespace
            if
                F =:= file2tab; F =:= tabfile_info; F =:= module_info; A =:= [] ->
                    apply(ets, F, A);
                F =:= foldl; F =:= foldr ->
                    [Fun, Acc, Tab] = A,
                    if
                        is_atom(Tab) ->
                            apply(ets, F, [Fun, Acc, encode_ets_name(Tab)]);
                        true ->
                            apply(ets, F, A)
                    end;
                F =:= info, length(A) =:= 1 ->
                    [Tab] = A,
                    case if
                             is_atom(Tab) ->
                                 apply(ets, F, [encode_ets_name(Tab)]);
                             true ->
                                 apply(ets, F, A)
                         end of
                        List when is_list(List) ->
                            lists:foldr(
                              fun ({K, V}, R) ->
                                      case K of
                                          name ->
                                              [{K, decode_ets_name(V)} | R];
                                          _ ->
                                              [{K, V} | R]
                                      end
                              end, [], List);
                        undefined ->
                            undefined
                    end;
                F =:= info, length(A) =:= 2 ->
                    [Tab, Item] = A,
                    Result =
                        if
                            is_atom(Tab) ->
                                apply(ets, F, [encode_ets_name(Tab), Item]);
                            true ->
                                apply(ets, F, A)
                        end,
                    case Item of
                        name when Result =/= undefined  ->
                            decode_ets_name(Result);
                        _Other ->
                            Result
                    end;
                F =:= new ->
                    [Name, Opts] = A,
                    NewName = encode_ets_name(Name),
                    Tid = apply(ets, new, [NewName, Opts]),
                    case lists:keysearch(heir, 1, Opts) of
                        false ->
                            ok;
                        {value, {heir, none}} ->
                            ok;
                        {value, {heir, Heir, HeirData}} ->
                            ?SHTABLE_SET(get_shtab(), {heir, Tid}, {Heir, HeirData})
                    end,
                    case Tid of
                        NewName -> Name;
                        _ -> Tid
                    end;
                F =:= give_away ->
                    [Tid, Pid, GiftData] = A,
                    RealTid =
                        if
                            is_atom(Tid) ->
                                encode_ets_name(Tid);
                            true -> Tid
                        end,
                    Result = apply(ets, F, [RealTid, Pid, morpheus_internal]),
                    GiveMsg = {'ETS-TRANSFER', Tid, self(), GiftData},
                    {ok, ok} = ?cc_send_msg(get_ctl(), Ann, self(), Pid, GiveMsg),
                    Result;
                true ->
                    [Tid | Rest] = A,
                    RealTid =
                        if
                            is_atom(Tid) ->
                                encode_ets_name(Tid);
                            true -> Tid
                        end,
                    Result = apply(ets, F, [RealTid | Rest]),
                    if
                        F =:= setopts ->
                            [Opts] = Rest,
                            case lists:keysearch(heir, 1, Opts) of
                                false -> ok;
                                {value, {heir, none}} ->
                                    ?SHTABLE_REMOVE(get_shtab(), {heir, RealTid});
                                {value, {heir, Pid, HeirData}} ->
                                    ?SHTABLE_REMOVE(get_shtab(), {heir, RealTid}),
                                    ?SHTABLE_SET(get_shtab(), {heir, RealTid}, {Pid, HeirData})
                            end;
                        true -> ok
                    end,
                    Result
            end
    end.

encode_ets_name(Name) ->
    %% XXX this is ugly!
    Prefix = "$E$" ++ pid_to_list(get_ctl()) ++ "$" ++ atom_to_list(get_node()) ++ "$",
    list_to_atom(Prefix ++ atom_to_list(Name)).

decode_ets_name(Name) ->
    %% XXX this is ugly!
    Prefix = "$E$" ++ pid_to_list(get_ctl()) ++ "$" ++ atom_to_list(get_node()) ++ "$",
    list_to_atom(atom_to_list(Name) -- Prefix).

start_node(Node, M, F, A) ->
    Ctl = get_ctl(),
    {ok, ok} = ?cc_node_created(Ctl, node_start, Node),
    Opt = get_opt(),
    ShTab = get_shtab(),
    {ok, EM, EF} = get_instrumented_func(Ctl, node_start, M, F, length(A)),
    {ok, GIM, GIF} = get_instrumented_func(Ctl, node_start, morpheus_guest_internal, init, []),
    Pid = spawn(fun () ->
                        %% virtual init process!
                        erlang:group_leader(self(), self()),
                        instrumented_process_start(Ctl, Node, Opt, ShTab),
                        apply(GIM, GIF, []),
                        instrumented_process_end(?CATCH(apply(EM, EF, A)))
                end),
    instrumented_process_created(Ctl, node_start, ShTab, Node, Pid),
    instrumented_process_kick(Ctl, Node, Pid),
    Ctl.

set_flag(tracing, Enabled) ->
    SHT = get_shtab(),
    ?SHTABLE_SET(SHT, tracing, Enabled).
