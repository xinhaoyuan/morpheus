-module(morpheus_instrument).

%% API exports
-export([instrument_and_load/6, whitelist_func/3]).

-include("morpheus_priv.hrl").

%%====================================================================
%% API functions
%%====================================================================

%% Instrument a module with object code `ObjectCode` and module name `OriginalModule`.
%% During the function, the instrumented module will be loaded, where:
%%   - The module is renamed to `NewModule` (NewModule is supposed to be globally unique)
%%   - call M:F(A...) is redirected to CtlMod:handle(OriginalModule, NewModule, call, M, F, A, _Ann)
%%   - apply(M, F, A) is redirected to CtlMod:handle(OriginalModule, NewModule, apply, M, F, A, _Ann)
%%   - T ! M is transformed to CtlMod:handle(OriginalModule, NewModule, call, erlang, send, [T, M], _Ann)
%%   - receive ... after ... end is transformed to case CtlMod:handle(OriginalModule, NewModule, 'receive', [PatFun, Timeout], _Ann) of ... end
%%   - Nif stubs in the new module are forwarding calls to the original stubs
%%   - _Ann is code annotation that is unused for now
%% If success, {ok, Warnings} will be returned.
%% Otherwise, failed will be returned
instrument_and_load(CtlMod, CtlState, OriginalModule, NewModule, Filename, ObjectCode) ->
    ?DEBUG("instrument(~w, ~w, ~w, ~p, ...)", [CtlMod, OriginalModule, NewModule, Filename]),
    Core = get_core(ObjectCode),
    ?VERBOSE_DEBUG("~w: gonna instrument ~p", [?FUNCTION_NAME, Core]),
    _InstrResult = {{Original, Instrumented}, CtlState0, Nifs, Warnings} = instrument_core(CtlMod, CtlState, Core, OriginalModule, NewModule),
    case Filename of
        [] ->
            case Original of
                undefined ->
                    code:load_binary(OriginalModule, [], ObjectCode);
                _ ->
                    load_module_from_core(OriginalModule, [], Original)
            end;
        _ ->
            case Original of
                undefined ->
                    {module, OriginalModule} = code:ensure_loaded(OriginalModule);
                _ ->
                    ?DEBUG("Reload original module ~p", [OriginalModule]),
                    load_module_from_core(OriginalModule, Filename, Original)
            end
    end,
    load_module_from_core(NewModule, Filename, Instrumented),
    {ok, CtlState0, Nifs, Warnings}.

%%====================================================================
%% Internal functions
%%====================================================================

load_module_from_core(Name, Filename, Core) ->
    ?DEBUG("load_module_from_core: ~p", [Name]),
    CompResult = compile:forms(Core, [from_core, report_errors, binary]),
    Binary =
        case CompResult of
            {ok, _, _Binary} ->
                _Binary;
            _Other ->
                ?WARNING("compile failed on module ~p:~n"
                         "  info: ~p~n"
                        ,[Name, _Other]),
                error(load_module_failed)
        end,
    {module, Name} = code:load_binary(Name, Filename, Binary),
    ok.

%% Some functions are inspired by Concuerror

get_core(CodeOrFilename) ->
    {ok, {Module, [{abstract_code, ChunkInfo}]}} =
        beam_lib:chunks(CodeOrFilename, [abstract_code]),
    case ChunkInfo of
        {_, Chunk} ->
            {ok, Module, Core} = compile:forms(Chunk, [binary, to_core0]),
            Core;
        no_abstract_code ->
            {ok, {Module, [{compile_info, CompileInfo}]}} =
                beam_lib:chunks(CodeOrFilename, [compile_info]),
            {source, File} = proplists:lookup(source, CompileInfo),
            {options, CompileOptions} = proplists:lookup(options, CompileInfo),
            Filter =
                fun(Option) ->
                        lists:member(element(1, Option), [d, i, parse_transform])
                end,
            CleanOptions = lists:filter(Filter, CompileOptions),
            Options = [debug_info, report_errors, binary, to_core0|CleanOptions],
            {ok, Module, Core} = compile:file(File, Options),
            Core
    end.

-record(ins_state, { nif_error_found :: boolean(), nifs :: [{atom(), integer()}], debug_counter :: integer() }).

instrument_core(CtlMod, CtlState, Core, OriginalModule, NewModule) ->
    Opt = {CtlMod, OriginalModule, NewModule},
    {R, {Opt, CtlState0, #ins_state{nifs = Nifs}, Warn}} =
        cerl_trees:mapfold(fun instrument_core_tree/2,
                           {Opt, CtlState,
                            #ins_state{nif_error_found = false, nifs = [], debug_counter = 0},
                            []}, Core),
    ToExport = case OriginalModule of
                   erl_eval ->
                       [{match_clause, 5} | Nifs];
                   _ ->
                       Nifs
               end,
    case ToExport of
        [] ->
            {{undefined, R}, CtlState0, [], Warn};
        _ ->
            %% XXX some module cannot be loaded twice due to on_load handler limitation
            ToReload =
                case code:is_sticky(OriginalModule) of
                    false -> true;
                    true ->
                        code:unstick_mod(OriginalModule)
                end,
            case ToReload of
                true ->
                    ?DEBUG("Reload original module of ~w with export list: ~p", [OriginalModule, ToExport]),
                    {ModifiedOriginal, _} = cerl_trees:mapfold(fun export_fun/2, ToExport, Core),
                    {{ModifiedOriginal, R},
                     CtlState0,
                     %% Since NIFs is not handled specially anywhere except in the process entry (and it's rare!), simply pass []
                     %% IS#ins_state.nifs,
                     [],
                     Warn};
                false ->
                    ?INFO("Skip reloading module ~p", [OriginalModule]),
                    {{undefined, R}, CtlState0, [], Warn}
            end
    end.

export_fun(Tree, FunList) ->
    Type = cerl:type(Tree),
    case Type of
        module ->
            NewTree = cerl:update_c_module(
                        Tree,
                        cerl:module_name(Tree),
                        lists:foldr(fun (V, Acc) ->
                                            [ cerl:c_var(V) | Acc ]
                                    end, [], FunList) ++ cerl:module_exports(Tree),
                        cerl:module_attrs(Tree),
                        cerl:module_defs(Tree)),
            {NewTree, FunList};
        _ ->
            {Tree, FunList}
    end.

%% Currently, we identify nif overrides by assuming that the nif stubs will call nif_error to generate error
instrument_core_tree(Tree, {{CtlMod, OriginalModule, NewModule} = Opt, CtlState, IS, Warnings}) ->
    Type = cerl:type(Tree),
    {NewTreeAndMaybeWarn, CtlState0, NewIS} =
        case Type of
            module ->
                _OriginalModule = cerl:atom_val(cerl:module_name(Tree)),
                %% Ignore on_load property assuming it's only loading NIF binaries,
                %% and the original module already handled it.
                NewAttrs = lists:foldr(
                             fun ({NameTree, ValueTree}, Acc) ->
                                     Name = cerl:concrete(NameTree),
                                     case Name of
                                         on_load ->
                                             Acc;
                                         _ ->
                                             [{NameTree, ValueTree} | Acc]
                                     end
                             end, [], cerl:module_attrs(Tree)),
                {Nifs, ToExpose, DefsWithForwarding} =
                    lists:foldr(
                      fun ({NT, DT}, {NifsL, ToExposeL0, DefsL}) ->
                              N = cerl:var_name(NT),
                              {F, A} = N,
                              Vars = cerl:fun_vars(DT),
                              Body = cerl:fun_body(DT),
                              IsNifStub = lists:member(nif_stub, cerl:get_ann(DT)),
                              ToExposeL =
                                  case erlang:function_exported(CtlMod, to_expose, 4)
                                      andalso CtlMod:to_expose(CtlState, OriginalModule, F, A) of
                                      true ->
                                          [{F, A} | ToExposeL0];
                                      false ->
                                          ToExposeL0
                                  end,
                              case N =/= {on_load, 0}
                                  andalso erlang:function_exported(CtlMod, to_override, 4)
                                  andalso CtlMod:to_override(CtlState, OriginalModule, F, A) of
                                  {true, Action}
                                    when Action =:= trace; Action =:= callback ->
                                      OrigName =
                                          case IsNifStub of
                                              true ->
                                                  [];
                                              false ->
                                                  list_to_atom(atom_to_list(F) ++ "$orig")
                                          end,
                                      InspectedBody = inspect( override
                                                             , [ cerl:c_atom(Action)
                                                               , cerl:c_atom(F)
                                                               , cerl:c_atom(OrigName)
                                                               , cerl:make_list(Vars)
                                                               ]
                                                             , Body, Opt),
                                      OverridedDef = cerl:update_c_fun(DT, Vars, InspectedBody),
                                      case IsNifStub of
                                          true ->
                                              {[N | NifsL], ToExposeL, [{NT, OverridedDef} | DefsL]};
                                          false ->
                                              OrigNT = {OrigName, A},
                                              {NifsL, [OrigNT | ToExposeL], 
                                               [{NT, OverridedDef}, {cerl:c_var(OrigNT), DT} | DefsL]}
                                      end;
                                  false when N =:= {on_load, 0} ->
                                      ?INFO("ignored on_load/0", []),
                                      {NifsL, ToExposeL, DefsL};
                                  false when IsNifStub ->
                                      UpdatedDef =
                                          case CtlMod:is_undet_nif(CtlState, OriginalModule, F, A) of
                                              true ->
                                                  InspectedBody = inspect(undet_nif_stub, [cerl:c_atom(element(1, N)), cerl:make_list(Vars)], Body, Opt),
                                                  cerl:update_c_fun(DT, Vars, InspectedBody);
                                              false ->
                                                  cerl:update_c_fun(
                                                    DT, Vars,
                                                    cerl:update_tree(DT, call,
                                                                     [[cerl:c_atom(OriginalModule)],
                                                                      [cerl:c_atom(F)],
                                                                      Vars]))
                                          end,
                                      {[N | NifsL], ToExposeL, [{NT, UpdatedDef} | DefsL]};
                                  false ->
                                      {NifsL, ToExposeL, [{NT, DT} | DefsL]}
                              end
                      end, {[], [], []}, cerl:module_defs(Tree)),
                NewExports = lists:usort(cerl:module_exports(Tree) ++
                                              lists:foldr(fun (VN, Acc) -> [cerl:c_var(VN) | Acc] end, [], ToExpose))
                    -- [cerl:c_var({on_load, 0})]
                    ,
                {cerl:update_c_module(
                   Tree,
                   cerl:c_atom(NewModule),
                   NewExports,
                   NewAttrs,
                   DefsWithForwarding),
                 CtlState, IS#ins_state{nifs = Nifs}};
            'fun' ->
                case IS#ins_state.nif_error_found of
                    true ->
                        {cerl:add_ann([nif_stub], Tree),
                         CtlState, IS#ins_state{nif_error_found = false}};
                    false ->
                        {Tree, CtlState, IS}
                end;
            apply ->
                Op = cerl:apply_op(Tree),
                case cerl:is_c_fname(Op) of
                    true ->
                        case cerl:fname_id(Op) of
                            %% Some modules (crypto I'm looking at you) wrap nif_error in their own function ...
                            nif_stub_error ->
                                {Tree, CtlState, IS#ins_state{nif_error_found = true}};
                            _ ->
                                ?VERBOSE_DEBUG("~w: ignore c_fname apply ~p", [?FUNCTION_NAME, Op]),
                                {Tree, CtlState, IS}
                        end;
                    false ->
                        OldArgs = cerl:make_list(cerl:apply_args(Tree)),
                        {inspect(apply, [Op, OldArgs], Tree, Opt), CtlState, IS}
                end;
            call ->
                Module = cerl:call_module(Tree),
                Name = cerl:call_name(Tree),
                Args = cerl:call_args(Tree),
                Arity = length(Args),
                ?DEBUG("~w: call ~p", [?FUNCTION_NAME, {Module, Name, Arity}]),
                {Tree1, ToInspect, _CtlState, IS0} =
                    case cerl:is_literal(Module) andalso cerl:is_literal(Name) andalso
                        {cerl:concrete(Module), cerl:concrete(Name), Arity} of
                        false ->
                            {Tree, true, CtlState, IS};
                        {erlang, nif_error, _} ->
                            {Tree, false, CtlState, IS#ins_state{nif_error_found = true}};
                        {erlang, node, 0} ->
                            %% HACK: prevent compiling erlang:node() into node vm instruction
                            {cerl:update_tree(Tree, call,
                                              [[cerl:c_atom(erlang)], [cerl:c_atom(node)],
                                               [cerl:update_tree(Tree, call, [[cerl:c_atom(erlang)], [cerl:c_atom(self)], []])]]),
                             false, CtlState, IS};
                        {M, F, A} ->
                            case whitelist_func(M, F, A) of
                                true ->
                                    {Tree, false, CtlState, IS};
                                false ->
                                    {_A, _B} = CtlMod:to_handle(
                                                 CtlState, OriginalModule, NewModule,
                                                 {call, erlang, F, A}),
                                    {Tree, _A, _B, IS}
                            end
                    end,
                ?VERBOSE_DEBUG("~w: to instrument? ~p", [?FUNCTION_NAME, ToInspect]),
                case ToInspect of
                    true ->
                        {inspect(call, [Module, Name, cerl:make_list(Args)], Tree1, Opt), _CtlState, IS0};
                    false ->
                        {Tree1, _CtlState, IS0}
                end;
            'receive' ->
                PatFun = receive_matching_fun(Tree),
                Clauses = cerl:receive_clauses(Tree),
                Timeout = cerl:receive_timeout(Tree),
                TimeoutAction = cerl:receive_action(Tree),
                InspectedMsgTree = inspect('receive', [PatFun, Timeout], Tree, Opt),
                TransformedClauses = transform_receive_clauses(Clauses, TimeoutAction),
                Tree1 = cerl:update_tree(Tree, 'case', [[InspectedMsgTree], TransformedClauses]),
                {Tree1, CtlState, IS};
            _ ->
                {Tree, CtlState, IS}
        end,
    {NewTree, NewWarnings} =
        case NewTreeAndMaybeWarn of
            {warn, NT, W} -> {NT, [W|Warnings]};
            _ -> {NewTreeAndMaybeWarn, Warnings}
        end,
    {NewTree, {Opt, CtlState0, NewIS, NewWarnings}}.

inspect(Tag, Args, Tree, {CtlMod, OriginalModule, NewModule}) ->
    CTag = cerl:c_atom(Tag),
    CArgs = cerl:make_list(Args),
    cerl:update_tree(Tree, call,
                     [[cerl:c_atom(CtlMod)],
                      [cerl:c_atom(handle)],
                      [cerl:c_atom(OriginalModule), cerl:c_atom(NewModule),
                       CTag, CArgs,
                       cerl:abstract(cerl:get_ann(Tree))]]).

receive_matching_fun(Tree) ->
    Msg = cerl:c_var(message),
    case cerl:receive_clauses(Tree) of
        [] ->
            %% this could happen in receive after X -> Y end
            cerl:ann_c_atom(cerl:get_ann(Tree), undefined);
        Clauses ->
            PatClauses = extract_patterns(Clauses),
            Body = cerl:update_tree(Tree, 'case', [[Msg], PatClauses]),
            cerl:update_tree(Tree, 'fun', [[Msg], [Body]])
    end.

extract_patterns(Clauses) ->
    extract_patterns(Clauses, []).

extract_patterns([], Acc) ->
    Pat = [cerl:c_var(message)],
    Guard = cerl:c_atom(true),
    Body = cerl:c_atom(false),
    lists:reverse([cerl:c_clause(Pat, Guard, Body)|Acc]);
extract_patterns([Tree|Rest], Acc) ->
    Body = cerl:c_atom(true),
    Pats = cerl:clause_pats(Tree),
    Guard = cerl:clause_guard(Tree),
    extract_patterns(Rest, [cerl:update_c_clause(Tree, Pats, Guard, Body)|Acc]).

transform_receive_clauses(Clauses, TimeoutAction) ->
    transform_receive_clauses(Clauses, [], TimeoutAction).

transform_receive_clauses([], Acc, TimeoutAction) ->
    lists:reverse([cerl:update_c_clause(TimeoutAction,
                                        %%%% this wil trigger failure in OTP-22-dev
                                        %% [cerl:c_atom(timeout)],
                                        [cerl:c_var(anything)],
                                        cerl:c_atom(true), TimeoutAction) | Acc]);
transform_receive_clauses([Tree | Rest], Acc, TimeoutAction) ->
    [Pat] = cerl:clause_pats(Tree),
    Guard = cerl:clause_guard(Tree),
    Body = cerl:clause_body(Tree),
    transform_receive_clauses(
      Rest,
      [cerl:update_c_clause(
         Tree, [cerl:c_cons(cerl:c_atom(message), Pat)], Guard, Body)
       | Acc],
      TimeoutAction).

whitelist_func(lists, _, _) -> true;
whitelist_func(queue, _, _) -> true;
whitelist_func(proplists, _, _) -> true;
whitelist_func(dict, _, _) -> true;
whitelist_func(orddict, _, _) -> true;
whitelist_func(math, _, _) -> true;
whitelist_func(maps, _, _) -> true;
whitelist_func(gb_sets, _, _) -> true;
whitelist_func(gb_trees, _, _) -> true;
whitelist_func(sets, _, _) -> true;
whitelist_func(re, _, _) -> true;
whitelist_func(binary, _, _) -> true;
whitelist_func(string, _, _) -> true;
whitelist_func(unicode, _, _) -> true;
whitelist_func(crypto, _, _) -> true;
whitelist_func(io_lib, _, _) -> true;
%% XXX could not instrument zlib properly - seems nif stub related
whitelist_func(zlib, _, _) -> true;
whitelist_func(filename, _, _) -> true;
whitelist_func(erl_internal, _, _) ->true;
whitelist_func(erl_parse, _, _) -> true;
whitelist_func(erl_lint, _, _) -> true;
whitelist_func(erl_prim_loader, _, _) -> true;
whitelist_func(erl_anno, _, _) -> true;
whitelist_func(erl_scan, _, _) -> true;
whitelist_func(erts_internal, _, _) -> true;
whitelist_func(erlang, error, _) -> true;
whitelist_func(erlang, F, A) ->
    (erl_internal:guard_bif(F, A)
     orelse erl_internal:arith_op(F, A)
     orelse erl_internal:bool_op(F, A)
     orelse erl_internal:comp_op(F, A));
whitelist_func(_, _, _) ->
    false.
