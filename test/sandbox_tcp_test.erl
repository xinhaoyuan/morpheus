-module(sandbox_tcp_test).

-include_lib("eunit/include/eunit.hrl").

-compile(export_all).

all_test_() ->
    [ ?_test( dummy )
    , {timeout, 120, ?_test( t_basic() )}
    ].

t_basic() ->
    {Ctl, MRef} = morpheus_sandbox:start(
                    ?MODULE, basic_test_entry, [],
                    [ monitor
                    , {fd_opts,
                       [{scheduler,
                         {basicpos, []}}]}
                    ]),
    success = receive {'DOWN', MRef, _, _, Reason} -> Reason end,
    ok.

-define(GH, morpheus_guest_helper).
-define(G, morpheus_guest).

do_recv(Sock, Bs) ->
    case gen_tcp:recv(Sock, 0) of
        {ok, B} ->
            do_recv(Sock, [Bs, B]);
        {error, closed} ->
            {ok, list_to_binary(Bs)}
    end.

basic_test_entry() ->
    ?GH:bootstrap(),
    %% passive recv
    ?GH:sync_task(
       [ par
       , fun () ->
                 {ok, LSock} = gen_tcp:listen(29999, [binary, {packet, 0},
                                                      {active, false}]),
                 {ok, Sock} = gen_tcp:accept(LSock),
                 {ok, Bin} = do_recv(Sock, []),
                 ok = gen_tcp:close(Sock),
                 ok = gen_tcp:close(LSock),
                 io:format(user, "Recv ~p~n", [Bin])
         end
       , fun () ->
                 {ok, Sock} = gen_tcp:connect("localhost", 29999,
                                              [binary, {packet, 0}]),
                 ok = gen_tcp:send(Sock, "Some Data"),
                 ok = gen_tcp:close(Sock)
         end
       ]),
    %% active recv
    ?GH:sync_task(
       [ par
       , fun () ->
                 {ok, LSock} = gen_tcp:listen(29999, [binary, {packet, 0},
                                                      {active, true}]),
                 {ok, Sock} = gen_tcp:accept(LSock),
                 Bin =
                     (fun F(BinList) ->
                              receive
                                  {tcp, _, X} ->
                                      F([X | BinList]);
                                  {tcp_closed, _} ->
                                      list_to_binary(lists:reverse(BinList))
                              end
                      end)([]),
                 ok = gen_tcp:close(Sock),
                 ok = gen_tcp:close(LSock),
                 io:format(user, "Recv ~p~n", [Bin])
         end
       , fun () ->
                 {ok, Sock} = gen_tcp:connect("localhost", 29999,
                                              [binary, {packet, 0}]),
                 ok = gen_tcp:send(Sock, "Some Data"),
                 ok = gen_tcp:close(Sock)
         end
       ]),
    ?G:exit_with(success),
    ok.
