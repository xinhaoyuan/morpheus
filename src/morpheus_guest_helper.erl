-module(morpheus_guest_helper).

-export([ bootstrap/0
        , bootstrap/1
        , bootstrap_remote/1
        , bootstrap_remote_entry/3
        ]).

-export([ async_task/1
        , sync_task/1
        ]).

%% %% Boot a minimum environment for unit-size tests
%% %% I've improved the real bootstrap process. This one seems not needed?
%% bootstrap() ->
%%     code:start_link(),
%%     {ok, _} = application_controller:start(
%%                 {application, kernel,
%%                  [{description, "morpheus sandbox mock kernel"},
%%                   {vsn, "0.0.0"},
%%                   {registered, []},
%%                   {mod, {morpheus_sandbox_mock_kernel, []}},
%%                   {applications, []},
%%                   %% Needed by error_logger
%%                   {env, []},
%%                   {modules, []},
%%                   {maintainers, []},
%%                   {licenses, []},
%%                   {links, []}
%%                  ]}),
%%     ok = application:load(
%%            {application, stdlib,
%%             [{description, "morpheus sandbox mock stdlib"},
%%              {vsn, "0.0.0"},
%%              {registered, []},
%%              {mod, {morpheus_sandbox_mock_stdlib, []}},
%%              {applications, []},
%%              {env, []},
%%              {modules, []},
%%              {maintainers, []},
%%              {licenses, []},
%%              {links, []}
%%             ]}),
%%     case erlang:function_exported(logger_server, start_link, 0) of
%%         true -> logger_server:start_link();
%%         false -> ok
%%     end,
%%     ok = application:start(kernel),
%%     ok = application:start(stdlib),
%%     ok.

%% Boot a real kernel and stdlib for tests that requires them.
%% One could take a look into the boot script that the real init module follows.
bootstrap() ->
    error_logger:start_link(),
    KernelInitAppInfo = morpheus_guest:get_kernel_app(),
    {ok, _} = application_controller:start(KernelInitAppInfo),
    case erlang:function_exported(logger_server, start_link, 0) of
        true -> logger_server:start_link();
        false -> ok
    end,
    ok = application:start(kernel),
    ok = application:start(stdlib),
    code:set_path(morpheus_guest:get_code_path()),
    ok.

bootstrap(Node) ->
    bootstrap(),
    {ok, _} = net_kernel:start([Node]).

bootstrap_remote(Node) ->
    Me = self(),
    Ref = make_ref(),
    morpheus_guest:start_node(Node, ?MODULE, bootstrap_remote_entry, [Me, Ref, Node]),
    receive Ref -> ok end.

bootstrap_remote_entry(Parent, Ref, Node) ->
    morpheus_guest_internal:init(),
    bootstrap(),
    {ok, _} = net_kernel:start([Node]),
    Parent ! Ref,
    %% As the init process, it seems required to keep it alive ...
    receive after infinity -> ok end.

async_task(F) when is_function(F) ->
    {_, MRef} = spawn_monitor(F),
    MRef;
async_task({M, F, A}) ->
    {_, MRef} = spawn_monitor(M, F, A),
    MRef;
async_task([seq, H]) ->
    async_task(H);
async_task([seq, H | R]) ->
    {_, M} = spawn_monitor(
               fun () ->
                       lists:foreach(fun (T) ->
                                             M = async_task(T),
                                             receive {'DOWN', M, _, _, _} -> ok end
                                     end, [H | R])
               end),
    M;
async_task([par, H]) ->
    async_task(H);
async_task([par, H | R]) ->
    {_, M} = spawn_monitor(
               fun () ->
                       Ms = lists:foldl(fun (T, Acc) ->
                                                [async_task(T) | Acc]
                                        end, [], [H | R]),
                       lists:foreach(fun (M) ->
                                             receive {'DOWN', M, _, _, _} -> ok end
                                     end, Ms)
               end),
    M;
async_task([par_map, C, T]) ->
    {_, M} = spawn_monitor(
               fun () ->
                       Ms = while(fun (N) -> if N < C -> {true, N + 1}; true -> false end end, 0,
                                  fun (L) -> [async_task(T) | L] end, []),
                       lists:foreach(fun (M) ->
                                             receive {'DOWN', M, _, _, _} -> ok end
                                     end, Ms)
               end),
    M;
async_task([loop, Cond, State, Body]) ->
    {_, M} = spawn_monitor(
               fun () ->
                       do_loop_sync(Cond, State, Body)
               end),
    M;
async_task([repeat, Times, Body]) ->
    {_, M} = spawn_monitor(
               fun () ->
                       do_loop_sync(fun (N) -> if N < Times -> {true, N + 1}; true -> false end end, 0, Body)
               end),
    M.

sync_task(F) when is_function(F) ->
    F();
sync_task({M, F, A}) ->
    apply(M, F, A);
sync_task([seq, T]) ->
    sync_task(T);
sync_task([par, T]) ->
    sync_task(T);
sync_task([loop, Cond, State, Body]) ->
    do_loop_sync(Cond, State, Body);
sync_task([repeat, Times, Body]) ->
    do_loop_sync(fun (N) -> if N < Times -> {true, N + 1}; true -> false end end, 0, Body);
sync_task(T) ->
    M = async_task(T),
    receive {'DOWN', M, _, _, _} -> ok end.

while(Cond, State, Body, Acc) ->
    case Cond(State) of
        {true, State0} ->
            Acc0 = Body(Acc),
            while(Cond, State0, Body, Acc0);
        _ ->
            Acc
    end.

do_loop_sync(Cond, State, Body) ->
    case Cond(State) of
        {true, State0} ->
            sync_task(Body),
            do_loop_sync(Cond, State0, Body);
        _ ->
            ok
    end.
